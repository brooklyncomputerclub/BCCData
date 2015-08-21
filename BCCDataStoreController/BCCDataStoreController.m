//
//  BCCDataStoreController.m
//
//  Created by Buzz Andersen on 3/24/11.
//  Copyright 2013 Brooklyn Computer Club. All rights reserved.
//

#import "BCCDataStoreController.h"
#import "BCCTargetActionQueue.h"
#import "NSFileManager+BCCAdditions.h"
#import "NSString+BCCAdditions.h"


// Notifications
NSString *BCCDataStoreControllerWillClearDatabaseNotification = @"BCCDataStoreControllerWillClearDatabaseNotification";
NSString *BCCDataStoreControllerDidClearDatabaseNotification = @"BCCDataStoreControllerDidClearDatabaseNotification";

NSString *BCCDataStoreControllerThreadMOCKey = @"BCCDataStoreControllerThreadMOCKey";

NSString *BCCDataStoreControllerCurrentUpdatedKeysUserInfoKey = @"BCCDataStoreControllerCurrentUpdatedKeysUserInfoKey";
NSString *BCCDataStoreControllerContextObjectCacheUserInfoKey = @"BCCDataStoreControllerContextObjectCacheUserInfoKey";

NSString *BCCDataStoreControllerWillClearIncompatibleDatabaseNotification = @"BCCDataStoreControllerWillClearIncompatibleDatabaseNotification";
NSString *BCCDataStoreControllerDidClearIncompatibleDatabaseNotification = @"BCCDataStoreControllerDidClearIncompatibleDatabaseNotification";


@interface BCCDataStoreController ()

@property (strong, nonatomic) NSString *rootDirectory;
@property (strong, nonatomic) NSString *mainPersistentStorePath;

@property (strong, nonatomic) NSManagedObjectModel *managedObjectModel;
@property (strong, nonatomic) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property (strong, nonatomic) NSPersistentStore *mainPersistentStore;

@property (strong, nonatomic) NSManagedObjectContext *writeMOC;
@property (strong, nonatomic) NSManagedObjectContext *mainMOC;
@property (strong, nonatomic) NSManagedObjectContext *backgroundMOC;

@property (strong, nonatomic) dispatch_queue_t workerQueue;

@property (strong, nonatomic) BCCTargetActionQueue *observerInfo;

@property (nonatomic) Class identityClass;

// Core Data Stack Management
- (void)initializeCoreDataStack;
- (void)initializeMainPersistentStore;
- (void)resetCoreDataStack;

// Persistent Stores
- (NSPersistentStore *)newPersistentStoreForCoordinator:(NSPersistentStoreCoordinator *)coordinator path:(NSString *)storePath;

// Saving
- (void)saveWriteMOC;
- (void)saveMOC:(NSManagedObjectContext *)managedObjectContext;

// Change Notifications
- (NSDictionary *)updatedEntityKeysForMOC:(NSManagedObjectContext *)managedObjectContext;
- (void)notifyObserversForChangeNotification:(NSNotification *)changeNotification;

// Worker MOC Object Caches
- (NSMutableDictionary *)objectCacheForMOC:(NSManagedObjectContext *)managedObjectContext;
- (void)clearObjectCacheForMOC:(NSManagedObjectContext *)managedObjectContext;
- (void)removeCacheObject:(NSManagedObject *)affectedObject;

// Identity
- (id)normalizedIdentityValueForValue:(id)value;
- (NSArray *)normalizedIdentityValueListForList:(NSArray *)valueList;
- (NSSet *)normalizedIdentityValueSetForSet:(NSSet *)valueSet;
- (NSString *)cacheKeyForIdentifier:(NSString *)identifier groupIdentifier:(NSString *)groupIdentifier;

@end


@interface BCCDataStoreTargetAction : BCCTargetAction

@property (nonatomic, retain) NSPredicate *predicate;
@property (nonatomic, retain) NSArray *requiredChangedKeys;

+ (BCCDataStoreTargetAction *)targetActionForKey:(NSString *)key withTarget:(id)target action:(SEL)action predicate:(NSPredicate *)predicate requiredChangedKeys:(NSArray *)changedKeys;

@end


@implementation BCCDataStoreController

#pragma mark - Class Methods

+ (NSString *)defaultRootDirectory
{
    NSMutableArray *pathComponents = [[NSMutableArray alloc] init];

    // If we're on a Mac, include the app name in the
    // application support path.
#if !TARGET_OS_IPHONE
    [pathComponents addObject:[[NSFileManager defaultManager] BCC_applicationSupportPathIncludingAppName]];
#else
    [pathComponents addObject:[[NSFileManager defaultManager] BCC_applicationSupportPath]];
#endif
    
    [pathComponents addObject:NSStringFromClass([self class])];
    
    NSString *path = [NSString pathWithComponents:pathComponents];
    
    return path;
}

#pragma mark - Initialization

- (id)initWithIdentifier:(NSString *)identifier modelPath:(NSString *)modelPath
{
    if (!(self = [self initWithIdentifier:identifier modelPath:modelPath rootDirectory:nil ])) {
        return nil;
    }
    
    return self;
}

- (id)initWithIdentifier:(NSString *)identifier modelPath:(NSString *)modelPath rootDirectory:(NSString *)rootDirectory
{
    if (!(self = [super init])) {
        return nil;
    }

    _identifier = identifier;
    
    _rootDirectory = rootDirectory ? rootDirectory : [BCCDataStoreController defaultRootDirectory];
    
    _managedObjectModelPath = modelPath;
    
    _workerQueue = NULL;
    
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveMainMOC) name:UIApplicationWillTerminateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveMainMOC) name:UIApplicationWillResignActiveNotification object:nil];
#elif TARGET_OS_MAC
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveMainMOC) name:NSApplicationWillTerminateNotification object:nil];
#endif
    
    self.observerInfo = [[BCCTargetActionQueue alloc] initWithIdentifier:identifier];
    
    [self initializeCoreDataStack];
    
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // This will release the main MOC, managed object model, and
    // persistent store coordinator
    [self resetCoreDataStack];
}

#pragma mark Accessors

- (void)setIdentifier:(NSString *)identifier
{
    if (![_identifier isEqualToString:identifier]) {
        [self deletePersistentStore];
    }
    
    _identifier = identifier;
    
    [self reset];
}

#pragma mark Core Data State

- (void)initializeCoreDataStack
{
    if (!self.managedObjectModelPath || ![[NSFileManager defaultManager] fileExistsAtPath:self.managedObjectModelPath isDirectory:NULL]) {
        NSLog(@"Unable to locate managed object model at path: %@", self.managedObjectModelPath);
        return;
    }

    if (!self.identifier) {
        self.identifier = NSStringFromClass([self class]);
    }
    
    // Set up the managed object model
    NSURL *modelURL = [NSURL fileURLWithPath:self.managedObjectModelPath];
    self.managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    
    // Set up root directory
    if (!self.rootDirectory) {
        self.rootDirectory = [[self class] defaultRootDirectory];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:self.rootDirectory]) {
        [[NSFileManager defaultManager] BCC_recursivelyCreatePath:self.rootDirectory];
    }

    // Set up the persistent store coordinator
    self.persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.managedObjectModel];
    
    // Set up the main persistent store
    [self initializeMainPersistentStore];
    
    // Set up the write MOC
    NSManagedObjectContext *writeMOC = [self newMOCWithConcurrencyType:NSMainQueueConcurrencyType];
    self.writeMOC = writeMOC;
    [self.writeMOC performBlockAndWait:^{
        writeMOC.persistentStoreCoordinator = self.persistentStoreCoordinator;
        writeMOC.mergePolicy = NSOverwriteMergePolicy;
    }];
    
    // Set up main thread context (for querying)
    NSManagedObjectContext *mainMOC = [self newMOCWithConcurrencyType:NSMainQueueConcurrencyType];
    self.mainMOC = mainMOC;
    [self.mainMOC performBlockAndWait:^{
        mainMOC.parentContext = writeMOC;
        mainMOC.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy;
    }];
    
    // Set up background private queue context
    NSManagedObjectContext *backgroundMOC = [self newMOCWithConcurrencyType:NSPrivateQueueConcurrencyType];
    self.backgroundMOC = backgroundMOC;
    [backgroundMOC performBlockAndWait:^{
        backgroundMOC.parentContext = mainMOC;
    }];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mainMOCDidSave:) name:NSManagedObjectContextDidSaveNotification object:mainMOC];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(backgroundMOCDidSave:) name:NSManagedObjectContextDidSaveNotification object:backgroundMOC];
    
    // Set up worker queue
    NSString *workerName = [NSString stringWithFormat:@"com.brooklyncomputerclub.%@.WorkerQueue", NSStringFromClass([self class])];
    _workerQueue = dispatch_queue_create([workerName UTF8String], DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(_workerQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));

    self.identityClass = [NSString class];
    
    self.observerInfo.identifier = self.identifier;
}

- (void)initializeMainPersistentStore
{
    NSString *persistentStorePath = self.mainPersistentStorePath;
    if (!self.persistentStoreCoordinator || !persistentStorePath) {
        return;
    }
    
    self.mainPersistentStore = [self newPersistentStoreForCoordinator:self.persistentStoreCoordinator path:persistentStorePath];
    if (!self.mainPersistentStore) {
        [[NSNotificationCenter defaultCenter] postNotificationName:BCCDataStoreControllerWillClearIncompatibleDatabaseNotification object:self];
        
        // If we couldn't load the persistent store (likely due to database incompatibility)
        // delete the existing database and try again.
        [[NSFileManager defaultManager] removeItemAtPath:persistentStorePath error:NULL];
        
        self.mainPersistentStore = [self newPersistentStoreForCoordinator:self.persistentStoreCoordinator path:persistentStorePath];
        if (!self.mainPersistentStore) {
            NSLog(@"Could not load database after clearing!");
            exit(1);
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:BCCDataStoreControllerDidClearIncompatibleDatabaseNotification object:self];
    }
}

#pragma Core Data State

- (void)reset
{
    [self resetCoreDataStack];
    [self initializeCoreDataStack];
}

- (void)resetCoreDataStack
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSManagedObjectContextDidSaveNotification object:nil];
    
    if (_workerQueue) {
        dispatch_sync(_workerQueue, ^{ });
        _workerQueue = nil;
    }
    
    if (_backgroundMOC) {
        [self.backgroundMOC performBlockAndWait:^{ }];
        _backgroundMOC = nil;
    }
    
    if (_mainMOC) {
        [self.mainMOC performBlockAndWait:^{ }];
        _mainMOC = nil;
    }
    
    if (_writeMOC) {
        [self.writeMOC performBlockAndWait:^{ }];
        _writeMOC = nil;
    }
    
    _managedObjectModel = nil;
    
    _persistentStoreCoordinator = nil;
    _mainPersistentStore = nil;
}

- (void)deletePersistentStore
{
    if (!self.mainPersistentStore) {
        return;
    }
    
    // Remove persistent store file
    [[NSNotificationCenter defaultCenter] postNotificationName:BCCDataStoreControllerWillClearDatabaseNotification object:self];

    NSError *error = nil;
    if (![self.persistentStoreCoordinator removePersistentStore:self.mainPersistentStore error:&error]) {
        NSLog(@"Remove PSC Error: %@", error);
    }
    
    [[NSFileManager defaultManager] removeItemAtURL:self.mainPersistentStore.URL error:NULL];
    
    // Clear out Core Data stack
    [self resetCoreDataStack];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:BCCDataStoreControllerDidClearDatabaseNotification object:self];
}

#pragma mark - Accessors

- (NSString *)mainPersistentStorePath
{
    if (!self.rootDirectory || !self.identifier) {
        return nil;
    }
    
    return [self.rootDirectory stringByAppendingPathComponent:[self.identifier stringByAppendingPathExtension:@"sqlite"]];
}

#pragma mark - Persistent Stores

- (NSPersistentStore *)newPersistentStoreForCoordinator:(NSPersistentStoreCoordinator *)coordinator path:(NSString *)storePath
{
    if (!coordinator || !storePath) {
        return nil;
    }
    
    NSURL *storeURL = [NSURL fileURLWithPath:storePath];
    if (!storeURL) {
        return nil;
    }
    
    NSError *error = nil;
    NSPersistentStore *persistentStore = [coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:@{NSSQLitePragmasOption: @{@"journal_mode": @"WAL"}} error:&error];
    if (!persistentStore) {
        NSLog(@"Error creating persistent store: %@", error);
        return nil;
    }
    
    return persistentStore;
}

#pragma mark - Managed Object Contexts

- (NSManagedObjectContext *)newMOCWithConcurrencyType:(NSManagedObjectContextConcurrencyType)concurrencyType
{
    NSManagedObjectContext *newMOC = [[NSManagedObjectContext alloc] initWithConcurrencyType:concurrencyType];
    
    newMOC.undoManager = nil;
    
    [newMOC.userInfo setObject:[[NSMutableDictionary alloc] init] forKey:BCCDataStoreControllerContextObjectCacheUserInfoKey];
    
    return newMOC;
}

- (NSManagedObjectContext *)currentMOC
{
    if (![[NSThread currentThread] isMainThread]) {
        return self.backgroundMOC;
    }
    
    return self.mainMOC;
}

- (NSManagedObjectContext *)threadMOC
{
    if ([[NSThread currentThread] isMainThread]) {
        return self.mainMOC;
    }
    
    NSThread *currentThread = [NSThread currentThread];
    NSManagedObjectContext *threadMOC = [currentThread.threadDictionary valueForKey:BCCDataStoreControllerThreadMOCKey];
    
    if (!threadMOC) {
        threadMOC = [self newMOCWithConcurrencyType:self.backgroundMOC.concurrencyType];
        [threadMOC performBlockAndWait:^{
            threadMOC.parentContext = self.backgroundMOC;
        }];
        
        [currentThread.threadDictionary setValue:threadMOC forKey:BCCDataStoreControllerThreadMOCKey];
    }
    
    return threadMOC;
}

#pragma mark - Saving

- (void)saveCurrentMOC
{
    NSManagedObjectContext *currentMOC = [self currentMOC];
    [self saveMOC:currentMOC];
}

- (void)saveWriteMOC
{
    [self.writeMOC performBlockAndWait:^{
        NSError *error = nil;
        [self.writeMOC save:&error];
        
        if (error) {
            NSLog(@"BCCDataStoreController Write MOC Save Exception: %@", error);
            return;
        }
    }];
}

- (void)saveMainMOC
{
    [self saveMOC:self.mainMOC];
}

- (void)saveBackgroundMOC
{
    [self saveMOC:self.backgroundMOC];
}

- (void)saveMOC:(NSManagedObjectContext *)managedObjectContext
{
    if (!managedObjectContext) {
        return;
    }
    
    void (^saveBlock)(void) = ^{
        NSDictionary *updatedKeysInfo = [self updatedEntityKeysForMOC:managedObjectContext];
        if (updatedKeysInfo) {
            [managedObjectContext.userInfo setObject:updatedKeysInfo forKey:BCCDataStoreControllerCurrentUpdatedKeysUserInfoKey];
        }
        
        NSError *error = nil;
        [managedObjectContext save:&error];
        
        if (error) {
            NSLog(@"BCCDataStoreController MOC Save Exception: %@", error);
            return;
        }
    };
    
    if (managedObjectContext.concurrencyType == NSPrivateQueueConcurrencyType || managedObjectContext.concurrencyType == NSMainQueueConcurrencyType) {
        [managedObjectContext performBlockAndWait:saveBlock];
    } else {
        saveBlock();
    }
}

#pragma mark - Save Notifications

- (void)backgroundMOCDidSave:(NSNotification *)notification
{
    NSManagedObjectContext *changedMOC = notification.object;
    if (changedMOC != self.backgroundMOC) {
        return;
    }
    
    [self saveMainMOC];
}

- (void)mainMOCDidSave:(NSNotification *)notification
{
    NSManagedObjectContext *changedMOC = notification.object;
    if (changedMOC != self.mainMOC) {
        return;
    }

    [self saveWriteMOC];
    
    [self.mainMOC performBlockAndWait:^{
        [self notifyObserversForChangeNotification:notification];
    }];
}

#pragma mark - Queue Management

- (void)performWorkWithParameters:(BCCDataStoreControllerWorkParameters *)workParameters
{
    BCCDataStoreControllerWorkBlock workBlock = workParameters.workBlock;
    BCCDataStoreControllerWorkBlock postSaveBlock = workParameters.postSaveBlock;
    
    if (!workBlock) {
        return;
    }
    
    NSManagedObjectContext *managedObjectContext = self.mainMOC;
    BOOL save = workParameters.shouldSave;
    BOOL delay = workParameters.executionDelay;
    BOOL wait = NO;
    
    switch (workParameters.workExecutionStyle) {
        case BCCDataStoreControllerWorkExecutionStyleMainMOCAndWait:
            wait = YES;
            break;
        case BCCDataStoreControllerWorkExecutionStyleBackgroundMOC:
            managedObjectContext = self.backgroundMOC;
            break;
        case BCCDataStoreControllerWorkExecutionStyleBackgroundMOCAndWait:
            managedObjectContext = self.backgroundMOC;
            wait = YES;
            break;
        default:
            break;
    }
    
    void (^metaBlock)(void) = ^(void) {
        workBlock(self, managedObjectContext, workParameters);
        
        NSMutableDictionary *contextObjectCache = [self objectCacheForMOC:managedObjectContext];
        if (contextObjectCache) {
            [contextObjectCache removeAllObjects];
        }
        
        if (save) {
            [self saveMOC:managedObjectContext];
            
            if (postSaveBlock) {
                postSaveBlock(self, managedObjectContext, workParameters);
            }
        }
    };
    
    void (^executionBlock)(void) = ^(void) {
        if (managedObjectContext.concurrencyType == NSMainQueueConcurrencyType || managedObjectContext.concurrencyType == NSPrivateQueueConcurrencyType) {
            wait ? [managedObjectContext performBlockAndWait:metaBlock] : [managedObjectContext performBlock:metaBlock];
        } else {
            metaBlock();
        }
    };
    
    if (delay) {
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC);
        dispatch_after(popTime, self.workerQueue, executionBlock);
    } else {
        executionBlock();
    }
}

- (void)performBlockOnMainMOC:(BCCDataStoreControllerWorkBlock)block
{
    BCCDataStoreControllerWorkParameters *workParameters = [[BCCDataStoreControllerWorkParameters alloc] init];
    workParameters.workExecutionStyle = BCCDataStoreControllerWorkExecutionStyleMainMOC;
    workParameters.workBlock = block;
    
    [self performWorkWithParameters:workParameters];
}

- (void)performBlockOnMainMOCAndWait:(BCCDataStoreControllerWorkBlock)block
{
    BCCDataStoreControllerWorkParameters *workParameters = [[BCCDataStoreControllerWorkParameters alloc] init];
    workParameters.workExecutionStyle = BCCDataStoreControllerWorkExecutionStyleMainMOCAndWait;
    workParameters.workBlock = block;
    
    [self performWorkWithParameters:workParameters];
}

- (void)performBlockOnMainMOC:(BCCDataStoreControllerWorkBlock)block afterDelay:(NSTimeInterval)delay
{
    BCCDataStoreControllerWorkParameters *workParameters = [[BCCDataStoreControllerWorkParameters alloc] init];
    workParameters.workExecutionStyle = BCCDataStoreControllerWorkExecutionStyleMainMOC;
    workParameters.executionDelay = delay;
    workParameters.workBlock = block;
    
    [self performWorkWithParameters:workParameters];
}

- (void)performBlockOnBackgroundMOC:(BCCDataStoreControllerWorkBlock)block
{
    BCCDataStoreControllerWorkParameters *workParameters = [[BCCDataStoreControllerWorkParameters alloc] init];
    workParameters.workExecutionStyle = BCCDataStoreControllerWorkExecutionStyleBackgroundMOC;
    workParameters.workBlock = block;
    
    [self performWorkWithParameters:workParameters];
}

- (void)performBlockOnBackgroundMOCAndWait:(BCCDataStoreControllerWorkBlock)block
{
    BCCDataStoreControllerWorkParameters *workParameters = [[BCCDataStoreControllerWorkParameters alloc] init];
    workParameters.workExecutionStyle = BCCDataStoreControllerWorkExecutionStyleMainMOCAndWait;
    workParameters.workBlock = block;
    
    [self performWorkWithParameters:workParameters];
}

- (void)performBlockOnBackgroundMOC:(BCCDataStoreControllerWorkBlock)block afterDelay:(NSTimeInterval)delay
{
    BCCDataStoreControllerWorkParameters *workParameters = [[BCCDataStoreControllerWorkParameters alloc] init];
    workParameters.workExecutionStyle = BCCDataStoreControllerWorkExecutionStyleBackgroundMOC;
    workParameters.executionDelay = delay;
    workParameters.workBlock = block;
    
    [self performWorkWithParameters:workParameters];
}

- (void)performBlockOnThreadMOC:(BCCDataStoreControllerWorkBlock)block
{
    BCCDataStoreControllerWorkParameters *workParameters = [[BCCDataStoreControllerWorkParameters alloc] init];
    workParameters.workExecutionStyle = BCCDataStoreControllerWorkExecutionStyleThreadMOC;
    workParameters.workBlock = block;
    
    [self performWorkWithParameters:workParameters];
}

- (void)performBlockOnThreadMOCAndWait:(BCCDataStoreControllerWorkBlock)block
{
    BCCDataStoreControllerWorkParameters *workParameters = [[BCCDataStoreControllerWorkParameters alloc] init];
    workParameters.workExecutionStyle = BCCDataStoreControllerWorkExecutionStyleThreadMOCAndWait;
    workParameters.workBlock = block;
    
    [self performWorkWithParameters:workParameters];
}

#pragma mark - Worker Queue Object Cache

- (void)setCacheObject:(NSManagedObject *)cacheObject forMOC:(NSManagedObjectContext *)managedObjectContext entityName:(NSString *)entityName identifier:(NSString *)identifier groupIdentifier:(NSString *)groupIdentifier
{
    if (!cacheObject || !entityName || !identifier) {
        return;
    }
    
    NSMutableDictionary *objectCache = [self objectCacheForMOC:managedObjectContext];
    if (!objectCache) {
        return;
    }

    NSMutableDictionary *dictionaryForEntity = [objectCache objectForKey:entityName];
    if (!dictionaryForEntity) {
        dictionaryForEntity = [[NSMutableDictionary alloc] init];
        [objectCache setObject:dictionaryForEntity forKey:entityName];
    }
    
    NSString *cacheKey = [self cacheKeyForIdentifier:identifier groupIdentifier:groupIdentifier];
    if (!cacheKey) {
        return;
    }
    
    [dictionaryForEntity setObject:cacheObject forKey:cacheKey];
}

- (NSManagedObject *)cacheObjectForMOC:(NSManagedObjectContext *)managedObjectContext entityName:(NSString *)entityName identifier:(NSString *)identifier groupIdentifier:(NSString *)groupIdentifier
{
    if (!entityName || !identifier) {
        return nil;
    }
    
    NSDictionary *objectCache = [self objectCacheForMOC:managedObjectContext];
    if (!objectCache) {
        return nil;
    }
    
    NSDictionary *dictionaryForEntity = [objectCache objectForKey:entityName];
    if (!dictionaryForEntity) {
        return nil;
    }
    
    NSString *cacheKey = [self cacheKeyForIdentifier:identifier groupIdentifier:groupIdentifier];
    if (!cacheKey) {
        return nil;
    }
    
    NSManagedObject *object = [dictionaryForEntity objectForKey:cacheKey];
    return object;
}

- (void)removeCacheObject:(NSManagedObject *)affectedObject
{
    NSManagedObjectContext *managedObjectContext = affectedObject.managedObjectContext;
    
    NSDictionary *objectCache = [self objectCacheForMOC:managedObjectContext];
    if (!objectCache) {
        return;
    }
    
    NSString *entityName = affectedObject.entity.name;
    
    NSMutableDictionary *dictionaryForEntity = [objectCache objectForKey:entityName];
    if (!dictionaryForEntity) {
        return;
    }
    
    NSArray *cacheObjects = dictionaryForEntity.allValues;
    for (NSManagedObject *currentCacheObject in cacheObjects) {
        if (currentCacheObject != affectedObject) {
            continue;
        }
        
        [managedObjectContext deleteObject:currentCacheObject];
        break;
    }
}

- (void)removeCacheObjectForMOC:(NSManagedObjectContext *)managedObjectContext entityName:(NSString *)entityName identifier:(NSString *)identifier groupIdentifier:(NSString *)groupIdentifier
{
    NSDictionary *objectCache = [self objectCacheForMOC:managedObjectContext];
    if (!objectCache) {
        return;
    }
    
    NSMutableDictionary *dictionaryForEntity = [objectCache objectForKey:entityName];
    if (!dictionaryForEntity) {
        return;
    }
    
    NSString *cacheKey = [self cacheKeyForIdentifier:identifier groupIdentifier:groupIdentifier];
    if (!cacheKey) {
        return;
    }
    
    [dictionaryForEntity removeObjectForKey:cacheKey];
}

- (void)clearObjectCacheForMOC:(NSManagedObjectContext *)managedObjectContext
{
    NSMutableDictionary *objectCache = [self objectCacheForMOC:managedObjectContext];
    if (!objectCache) {
        return;
    }
    
    [objectCache removeAllObjects];
}

- (NSMutableDictionary *)objectCacheForMOC:(NSManagedObjectContext *)managedObjectContext
{
    if (!managedObjectContext) {
        return nil;
    }
    
    return [managedObjectContext.userInfo objectForKey:BCCDataStoreControllerContextObjectCacheUserInfoKey];
}

#pragma mark - Entity CRUD

- (NSManagedObject *)createAndInsertObjectWithEntityName:(NSString *)entityName
{
    if (!entityName) {
        return nil;
    }
    
    NSManagedObjectContext *managedObjectContext = [self currentMOC];
    
    NSEntityDescription *entity = [NSEntityDescription entityForName:entityName inManagedObjectContext:managedObjectContext];
    if (!entity) {
        return nil;
    }
    
    NSManagedObject *createdObject = [[NSClassFromString([entity managedObjectClassName]) alloc] initWithEntity:entity insertIntoManagedObjectContext:managedObjectContext];
    
    return createdObject;
}

- (NSManagedObject *)createAndInsertObjectWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier
{
    if (!entityName || !identityPropertyName || !identityValue) {
        return nil;
    }
    
    NSManagedObject *createdObject = [self createAndInsertObjectWithEntityName:entityName];
    if (!createdObject) {
        return nil;
    }

    id normalizedIdentityValue = [self normalizedIdentityValueForValue:identityValue];
    [createdObject setValue:normalizedIdentityValue forKey:identityPropertyName];
    
    if (groupIdentifier && groupPropertyName) {
        [createdObject setValue:groupIdentifier forKey:groupPropertyName];
    }

    [self setCacheObject:createdObject forMOC:[self currentMOC] entityName:entityName identifier:normalizedIdentityValue groupIdentifier:groupIdentifier];

    return createdObject;
}

- (NSManagedObject *)findOrCreateObjectWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier
{
    if (!entityName || !identityPropertyName || !identityValue) {
        return nil;
    }
    
    id normalizedIdentityValue = [self normalizedIdentityValueForValue:identityValue];
    if (!normalizedIdentityValue) {
        return nil;
    }
    
    NSManagedObject *object = nil;
    NSManagedObjectContext *managedObjectContext = [self currentMOC];
    
    object = [self cacheObjectForMOC:managedObjectContext entityName:entityName identifier:normalizedIdentityValue groupIdentifier:groupIdentifier];
    if (object) {
        return object;
    }
    
    NSMutableArray *propertyList = [[NSMutableArray alloc] initWithObjects:identityPropertyName, nil];
    NSMutableArray *valueList = [[NSMutableArray alloc] initWithObjects:normalizedIdentityValue, nil];
    if (groupPropertyName && groupIdentifier) {
        [propertyList addObject:groupPropertyName];
        [valueList addObject:groupIdentifier];
    }
    
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName usingPropertyList:propertyList valueList:valueList sortDescriptors:nil];
    
    object = [self performSingleResultFetchRequest:fetchRequest error:NULL];
    if (!object) {
        object = [self createAndInsertObjectWithEntityName:entityName identityProperty:identityPropertyName identityValue:identityValue groupPropertyName:groupPropertyName groupIdentifier:groupIdentifier];
        if (!object) {
            return nil;
        }
    }
    
    return object;
}

- (NSArray *)createObjectsOfEntityType:(NSString *)entityName fromDictionaryArray:(NSArray *)dictionaryArray usingImportParameters:(BCCDataStoreControllerImportParameters *)importParameters postCreateBlock:(BCCDataStoreControllerPostCreateBlock)postCreateBlock
{
    return [self createObjectsOfEntityType:entityName fromDictionaryArray:dictionaryArray findExisting:importParameters.findExisting dictionaryIdentityProperty:importParameters.dictionaryIdentityPropertyName modelIdentityProperty:importParameters.modelIdentityPropertyName groupPropertyName:importParameters.groupPropertyName groupIdentifier:importParameters.groupIdentifier postCreateBlock:postCreateBlock];
}

- (NSArray *)createObjectsOfEntityType:(NSString *)entityName fromDictionaryArray:(NSArray *)dictionaryArray findExisting:(BOOL)findExisting dictionaryIdentityProperty:(NSString *)dictionaryIdentityPropertyName modelIdentityProperty:(NSString *)modelIdentityPropertyName groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier postCreateBlock:(BCCDataStoreControllerPostCreateBlock)postCreateBlock
{
    if (!entityName || !dictionaryArray || dictionaryArray.count < 1) {
        return nil;
    }

    NSManagedObjectContext *managedObjectContext = [self currentMOC];
    
    NSMutableArray *affectedObjects = [[NSMutableArray alloc] init];
    
    [dictionaryArray enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSDictionary *currentDictionary = (NSDictionary *)obj;
        
        NSManagedObject *affectedObject = nil;
        id identifier = [currentDictionary valueForKeyPath:dictionaryIdentityPropertyName];
        if (!identifier && findExisting) {
            return;
        }
        
        if (findExisting) {
            affectedObject = [self findOrCreateObjectWithEntityName:entityName identityProperty:modelIdentityPropertyName identityValue:identifier groupPropertyName:groupPropertyName groupIdentifier:groupIdentifier];
        } else if (identifier) {
            affectedObject = [self createAndInsertObjectWithEntityName:entityName identityProperty:modelIdentityPropertyName identityValue:identifier groupPropertyName:groupPropertyName groupIdentifier:groupIdentifier];
        } else {
            affectedObject = [self createAndInsertObjectWithEntityName:entityName];
            
            if (groupIdentifier && groupPropertyName) {
                [affectedObject setValue:groupIdentifier forKey:groupPropertyName];
            }
        }
        
        if (!affectedObject) {
            return;
        }
        
        if (postCreateBlock) {
            postCreateBlock(affectedObject, currentDictionary, idx, managedObjectContext);
        }
        
        [affectedObjects addObject:affectedObject];

    }];
    
    return affectedObjects;
}

- (void)deleteObjects:(NSArray *)affectedObjects
{
    for (NSManagedObject *currentObject in affectedObjects) {
        [self removeCacheObject:currentObject];
        [[self currentMOC] deleteObject:currentObject];
    }
}

- (void)deleteObjectsWithEntityName:(NSString *)entityName
{
    if (!entityName) {
        return;
    }
    
    [self deleteObjectsWithEntityName:entityName identityProperty:nil identityValue:nil groupPropertyName:nil groupIdentifier:nil];
}

- (void)deleteObjectsWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier
{
    if (!entityName || (identityPropertyName && !identityValue)) {
        return;
    }
    
    NSArray *propertyList = nil;
    NSArray *valueList = nil;
    if (groupPropertyName && groupIdentifier) {
        propertyList = @[groupPropertyName];
        valueList = @[groupIdentifier];
    }
    
    NSArray *affectedObjects = [self performFetchOfEntityWithName:entityName usingPropertyList:propertyList valueList:valueList sortDescriptors:nil error:NULL];
    if (affectedObjects.count < 1) {
        return;
    }

    id normalizedIdentityValue = [self normalizedIdentityValueForValue:identityValue];
    
    NSManagedObjectContext *managedObjectContext = [self currentMOC];
    
    for (NSManagedObject *currentObject in affectedObjects) {
        [self removeCacheObjectForMOC:managedObjectContext entityName:entityName identifier:normalizedIdentityValue groupIdentifier:groupIdentifier];

        [managedObjectContext deleteObject:currentObject];
    }
}

// TO DO: Remove deleted objects from memory cache here

/*- (void)deleteObjectsWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName valueList:(NSArray *)valueList
{
    if (!entityName || identityPropertyName || valueList.count < 1) {
        return;
    }
    
    NSManagedObjectContext *context = [self currentContext];
    
    NSArray *normalizedValueList = [self normalizedIdentityValueListForList:valueList];
    NSArray *objectList = [self performFetchOfEntityWithName:entityName byProperty:identityPropertyName valueList:normalizedValueList sortDescriptors:nil error:NULL];
    if (objectList.count < 1) {
        return;
    }
    
    for (NSManagedObject *currentObject in objectList) {
        [context deleteObject:currentObject];
    }
}*/

#pragma mark - Identity

- (id)normalizedIdentityValueForValue:(id)value
{
    if (!value) {
        return nil;
    }
    
    if ([value isKindOfClass:self.identityClass]) {
        return value;
    }
    
    if (self.identityClass == [NSString class]) {
        if ([value isKindOfClass:[NSNumber class]]) {
            return [(NSNumber *)value stringValue];
        }
    }
    
    return nil;
}

- (NSArray *)normalizedIdentityValueListForList:(NSArray *)valueList
{
    if (valueList.count < 1) {
        return nil;
    }
    
    NSMutableArray *normalizedValueList = [[NSMutableArray alloc] init];
    for (id currentValue in valueList) {
        id currentNormalizedValue = [self normalizedIdentityValueForValue:currentValue];
        if (!currentNormalizedValue) {
            continue;
        }
        
        [normalizedValueList addObject:currentNormalizedValue];
    }
    
    return normalizedValueList;
}

- (NSSet *)normalizedIdentityValueSetForSet:(NSSet *)valueSet
{
    if (valueSet.count < 1) {
        return nil;
    }
    
    NSMutableSet *normalizedValueSet = [[NSMutableSet alloc] init];
    for (id currentValue in valueSet) {
        id currentNormalizedValue = [self normalizedIdentityValueForValue:currentValue];
        if (!currentNormalizedValue) {
            continue;
        }
        
        [normalizedValueSet addObject:currentNormalizedValue];
    }
    
    return normalizedValueSet;
}

- (NSString *)cacheKeyForIdentifier:(NSString *)identifier groupIdentifier:(NSString *)groupIdentifier
{
    if (!identifier) {
        return nil;
    }
    
    NSMutableString *keyString = [[NSMutableString alloc] initWithString:identifier];
    
    if (groupIdentifier) {
        [keyString appendFormat:@"-%@", groupIdentifier];
    }
    
    return [keyString BCC_MD5String];
}

#pragma mark - Higher Level Query Methods

- (NSArray *)objectsForEntityWithName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors
{
    return [self objectsForEntityWithName:entityName sortDescriptors:sortDescriptors groupPropertyName:nil groupIdentifier:nil filteredByProperty:nil valueSet:nil];
}

- (NSArray *)objectsForEntityWithName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier
{
    return [self objectsForEntityWithName:entityName sortDescriptors:sortDescriptors groupPropertyName:groupPropertyName groupIdentifier:groupIdentifier filteredByProperty:nil valueSet:nil];
}

- (NSArray *)objectsForEntityWithName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier filteredByProperty:(NSString *)propertyName valueSet:(NSSet *)valueSet
{
    if (!entityName) {
        return nil;
    }
    
    NSArray *propertyList = nil;
    NSArray *valueList = nil;
    
    if (groupPropertyName && groupIdentifier) {
        propertyList = @[groupPropertyName];
        valueList = @[groupIdentifier];
    }
    
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName usingPropertyList:propertyList valueList:valueList sortDescriptors:sortDescriptors];
    if (!fetchRequest) {
        return nil;
    }
    
    NSArray *fullObjectList = [self performFetchRequest:fetchRequest error:NULL];
    
    if (!propertyName || valueSet.count < 1) {
        return fullObjectList;
    }
    
    NSSet *normalizedValueSet = [self normalizedIdentityValueSetForSet:valueSet];
    if (!normalizedValueSet) {
        return nil;
    }
    
    NSMutableArray *affectedObjects = [[NSMutableArray alloc] init];
    
    [fullObjectList enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSManagedObject *currentObject = (NSManagedObject *)obj;
        id propertyValue = [currentObject valueForKey:propertyName];
        
        if (![normalizedValueSet containsObject:propertyValue]) {
            return;
        }
        
        [affectedObjects addObject:currentObject];
    }];
    
    return affectedObjects;
}

#pragma mark - Lower Level Query Methods

- (NSManagedObject *)performSingleResultFetchOfEntityWithName:(NSString *)entityName usingPropertyList:(NSArray *)propertyList valueList:(NSArray *)valueList error:(NSError **)error
{

    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName usingPropertyList:propertyList valueList:valueList sortDescriptors:nil];
    if (!fetchRequest) {
        return nil;
    }
    
    return [self performSingleResultFetchRequest:fetchRequest error:error];
}

- (NSArray *)performFetchOfEntityWithName:(NSString *)entityName usingPropertyList:(NSArray *)propertyList valueList:(NSArray *)valueList sortDescriptors:(NSArray *)sortDescriptors error:(NSError **)error
{
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName usingPropertyList:propertyList valueList:valueList sortDescriptors:sortDescriptors];
    if (!fetchRequest) {
        return nil;
    }
    
    return [self performFetchRequest:fetchRequest error:error];
}

- (NSArray *)performFetchOfEntityWithName:(NSString *)entityName byProperty:(NSString *)propertyName valueList:(NSArray *)valueList sortDescriptors:(NSArray *)sortDescriptors error:(NSError **)error
{
    if (!entityName || !propertyName || valueList.count < 1) {
        return nil;
    }
    
    NSArray *normalizedValueList = [self normalizedIdentityValueListForList:valueList];
    if (!normalizedValueList) {
        return nil;
    }
    
    NSMutableString *predicateString = [[NSMutableString alloc] init];
    NSMutableArray *argumentArray = [[NSMutableArray alloc] init];
    
    [predicateString appendString:@"(%K IN %@)"];
    
    [argumentArray addObject:propertyName];
    [argumentArray addObject:normalizedValueList];
    
    NSPredicate *listPredicate = [NSPredicate predicateWithFormat:predicateString argumentArray:argumentArray];
    
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName sortDescriptors:sortDescriptors];

    fetchRequest.predicate = listPredicate;
    
    return [self performFetchRequest:fetchRequest error:error];
}

- (NSManagedObject *)performSingleResultFetchRequestWithTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary error:(NSError **)error
{
    NSFetchRequest *fetchRequest = [self fetchRequestForTemplateName:templateName substitutionDictionary:substitutionDictionary sortDescriptors:nil];
    if (!fetchRequest) {
        return nil;
    }
    
    return [self performSingleResultFetchRequest:fetchRequest error:error];
}

- (NSArray *)performFetchRequestWithTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary sortDescriptors:(NSArray *)sortDescriptors error:(NSError **)error
{
    NSFetchRequest *fetchRequest = [self fetchRequestForTemplateName:templateName substitutionDictionary:substitutionDictionary sortDescriptors:sortDescriptors];
    if (!fetchRequest) {
        return nil;
    }
    
    return [self performFetchRequest:fetchRequest error:error];
}

- (NSManagedObject *)performSingleResultFetchRequest:(NSFetchRequest *)fetchRequest error:(NSError **)error
{
    if (!fetchRequest) {
        return nil;
    }
    
    fetchRequest.fetchLimit = 1;
    fetchRequest.fetchBatchSize = 1;
    
    NSArray *results = [self performFetchRequest:fetchRequest error:error];
    if (error) {
        NSLog(@"Error for single result fetch request %@: %@", fetchRequest, *error);
    }
    
    NSManagedObject *result = nil;
    if (results.count > 0) {
        result = [results objectAtIndex:0];
    }
    
    return result;
}

- (NSArray *)performFetchRequest:(NSFetchRequest *)fetchRequest error:(NSError **)error
{
    if (!fetchRequest) {
        return nil;
    }
    
    error = NULL;
    
    NSArray *results = [[self currentMOC] executeFetchRequest:fetchRequest error:error];
    if (error) {
        NSLog(@"Error for fetch request %@: %@", fetchRequest, *error);
    }
    
    return results;
}

#pragma mark - Fetch Request Creation

- (NSFetchRequest *)fetchRequestForEntityName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors
{
    if (!entityName) {
        return nil;
    }
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:entityName];
    
    if (sortDescriptors) {
        fetchRequest.sortDescriptors = sortDescriptors;
    }
    
    return fetchRequest;
}

- (NSFetchRequest *)fetchRequestForEntityName:(NSString *)entityName usingPropertyList:(NSArray *)propertyList valueList:(NSArray *)valueList sortDescriptors:(NSArray *)sortDescriptors
{
    if (!entityName || propertyList.count < 1 || valueList.count < 1 || propertyList.count != valueList.count) {
        return nil;
    }
    
    NSMutableArray *argumentArray = [[NSMutableArray alloc] init];
    NSMutableString *formatString = [[NSMutableString alloc] init];
    
    [propertyList enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        [argumentArray addObject:obj];
        [argumentArray addObject:valueList[idx]];
        
        [formatString BCC_appendPredicateCondition:@"%K == %@"];
    }];
    
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName sortDescriptors:sortDescriptors];
    
    NSPredicate *predicate = [NSPredicate predicateWithFormat:formatString argumentArray:argumentArray];
    fetchRequest.predicate = predicate;

    return fetchRequest;
}

- (NSFetchRequest *)fetchRequestForTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary sortDescriptors:(NSArray *)sortDescriptors
{
    if (!templateName) {
        return nil;
    }
    
    NSFetchRequest *fetchRequest = nil;
    if (substitutionDictionary) {
        fetchRequest = [[self.managedObjectModel fetchRequestFromTemplateWithName:templateName substitutionVariables:substitutionDictionary] copy];
    } else {
        fetchRequest = [[self.managedObjectModel fetchRequestTemplateForName:templateName] copy];
    }
    
    if (sortDescriptors) {
        fetchRequest.sortDescriptors = sortDescriptors;
    }
    
    return fetchRequest;
}
#pragma mark - Change Observation

- (void)notifyObserversForChangeNotification:(NSNotification *)changeNotification
{
    NSManagedObjectContext *managedObjectContext = changeNotification.object;
    
    NSSet *insertedObjects = [changeNotification.userInfo objectForKey:NSInsertedObjectsKey];
    NSSet *updatedObjects = [changeNotification.userInfo objectForKey:NSUpdatedObjectsKey];
    NSSet *deletedObjects = [changeNotification.userInfo objectForKey:NSDeletedObjectsKey];
    
    if (!managedObjectContext || (insertedObjects.count < 1 && updatedObjects.count < 1 && deletedObjects.count < 1)) {
        return;
    }

    NSDictionary *updatedKeysInfo = [managedObjectContext.userInfo objectForKey:BCCDataStoreControllerCurrentUpdatedKeysUserInfoKey];
    
    NSEnumerator *entityKeyEnumerator = [self.observerInfo keyEnumerator];
    NSMutableArray *safeKeyList = [[NSMutableArray alloc] init];
    for (NSString *currentKey in entityKeyEnumerator) {
        [safeKeyList addObject:currentKey];
    }
    
    for (NSString *currentEntityKey in safeKeyList) {
        NSSet *updatedKeysForCurrentEntity = [updatedKeysInfo objectForKey:currentEntityKey];
        
        BOOL (^entityTypeMatchTest)(id, BOOL *) = ^(id obj, BOOL *stop) {
            NSManagedObject *managedObject = (NSManagedObject *)obj;
            if ([managedObject.entity.name isEqualToString:currentEntityKey]) {
                return YES;
            }
            
            return NO;
        };
        
        NSSet *entityInsertedObjects = [insertedObjects objectsPassingTest:entityTypeMatchTest];
        NSSet *entityUpdatedObjects = [updatedObjects objectsPassingTest:entityTypeMatchTest];
        NSSet *entityDeletedObjects = [deletedObjects objectsPassingTest:entityTypeMatchTest];
        
        if (!entityInsertedObjects.count && !entityUpdatedObjects.count && !entityDeletedObjects.count) {
            continue;
        }
        
        [self.observerInfo enumerateTargetActionsForKey:currentEntityKey usingBlock:^(BCCTargetAction *targetAction) {
            BCCDataStoreTargetAction *currentTargetAction = (BCCDataStoreTargetAction *)targetAction;
            
            // By default, the changed objects are unfiltered
            NSSet *matchingInsertedObjects = entityInsertedObjects;
            NSSet *matchingUpdatedObjects = entityUpdatedObjects;
            NSSet *matchingDeletedObjects = entityDeletedObjects;
            
            // If a predicate was specified, filter the changed
            // objects list using that
            NSPredicate *currentPredicate = currentTargetAction.predicate;
            if (currentPredicate) {
                matchingInsertedObjects = [entityInsertedObjects filteredSetUsingPredicate:currentPredicate];
                matchingUpdatedObjects = [entityUpdatedObjects filteredSetUsingPredicate:currentPredicate];
                matchingDeletedObjects = [entityDeletedObjects filteredSetUsingPredicate:currentPredicate];
            }
            
            // If no changed objects are left after any applicable
            // predicate filtering, this target/action is not a match
            if (matchingInsertedObjects.count < 1 && matchingUpdatedObjects.count < 1 && matchingDeletedObjects.count < 1) {
                return;
            }
            
            NSArray *currentRequiredChangedKeys = [currentTargetAction.requiredChangedKeys copy];
            
            // If this target/action specifies required changed keys
            // and none of the predicate filtered updated object changes
            // match those, this is not a match
            BOOL changedKeysRequired = (currentRequiredChangedKeys.count > 0);
            if (changedKeysRequired && (matchingUpdatedObjects.count < 1 || updatedKeysForCurrentEntity.count < 1)) {
                return;
            }
            
            // If we have required changed keys, examine the
            // predicate matched updated objects for ones
            // with changes matching the required keys
            if (changedKeysRequired) {
                NSMutableSet *updatedObjectsMatchingChangedKeys = [[NSMutableSet alloc] init];
                
                for (NSManagedObject *currentUpdatedObject in [matchingUpdatedObjects allObjects]) {
                    for (NSString *currentChangedKey in updatedKeysForCurrentEntity) {
                        NSUInteger foundIndex = [currentRequiredChangedKeys indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
                            NSString *currentRequiredChangedKey = (NSString *)obj;
                            if ([currentRequiredChangedKey isEqualToString:currentChangedKey]){
                                *stop = YES;
                                return YES;
                            }
                            
                            return NO;
                        }];
                        
                        if (foundIndex != NSNotFound) {
                            [updatedObjectsMatchingChangedKeys addObject:currentUpdatedObject];
                        }
                    }
                }
                
                // If required changed keys were specified
                // but none were found, this target/action
                // is not a match
                if (updatedObjectsMatchingChangedKeys.count) {
                    matchingUpdatedObjects = updatedObjectsMatchingChangedKeys;
                } else {
                    return;
                }
            }
            
            NSMutableDictionary *changesets = [[NSMutableDictionary alloc] init];
            
            if (matchingInsertedObjects) {
                [changesets setObject:matchingInsertedObjects forKey:NSInsertedObjectsKey];
            }
            
            if (matchingUpdatedObjects) {
                [changesets setObject:matchingUpdatedObjects forKey:NSUpdatedObjectsKey];
            }
            
            if (matchingDeletedObjects) {
                [changesets setObject:matchingDeletedObjects forKey:NSDeletedObjectsKey];
            }
            
            BCCDataStoreChangeNotification *changeNotification = [[BCCDataStoreChangeNotification alloc] initWithDictionary:changesets];
            dispatch_sync(self.workerQueue, ^{
                [self.observerInfo performAction:currentTargetAction withObject:changeNotification];
            });
        }];
        
        [managedObjectContext.userInfo removeObjectForKey:BCCDataStoreControllerCurrentUpdatedKeysUserInfoKey];
    }
}

- (NSDictionary *)updatedEntityKeysForMOC:(NSManagedObjectContext *)managedObjectContext
{
    if (!managedObjectContext) {
        return nil;
    }
    
    NSSet *updatedObjects = managedObjectContext.updatedObjects;
    if (updatedObjects.count < 1) {
        return nil;
    }
    
    
    NSMutableDictionary *changedEntitiesDictionary = [[NSMutableDictionary alloc] init];
    for (NSManagedObject *currentUpdatedObject in updatedObjects) {
        NSString *currentEntityName = currentUpdatedObject.entity.name;
        
        NSMutableSet *changedKeysListForEntity = [changedEntitiesDictionary objectForKey:currentEntityName];
        if (!changedKeysListForEntity) {
            changedKeysListForEntity = [[NSMutableSet alloc] init];
            [changedEntitiesDictionary setObject:changedKeysListForEntity forKey:currentEntityName];
        }
        
        NSDictionary *currentObjectChangedValues = [currentUpdatedObject committedValuesForKeys:nil];
        NSEnumerator *changedKeysEnumerator = [currentObjectChangedValues keyEnumerator];
        for (NSString *currentChangedKey in changedKeysEnumerator) {
            [changedKeysListForEntity addObject:currentChangedKey];
        }
    }
    
    return changedEntitiesDictionary;
}

- (void)addObserver:(id)observer action:(SEL)action forEntityName:(NSString *)entityName
{
    [self addObserver:observer action:action forEntityName:entityName withPredicate:nil requiredChangedKeys:nil];
}

- (void)addObserver:(id)observer action:(SEL)action forEntityName:(NSString *)entityName withPredicate:(NSPredicate *)predicate requiredChangedKeys:(NSArray *)changedKeys
{
    BCCDataStoreTargetAction *targetAction = [BCCDataStoreTargetAction targetActionForKey:entityName withTarget:observer action:action predicate:predicate requiredChangedKeys:changedKeys];
        
    [self.observerInfo addTargetAction:targetAction];
}

- (BOOL)hasObserver:(id)observer
{
    NSArray *matchingTargetActions = [self.observerInfo targetActionsForTarget:observer];
    return (matchingTargetActions.count > 0);
}

- (BOOL)hasObserver:(id)observer forEntityName:(NSString *)entityName
{
    NSArray *matchingTargetActions = [self.observerInfo targetActionsForTarget:observer key:entityName];
    return (matchingTargetActions.count > 0);
}

- (void)removeObserver:(id)observer forEntityName:(NSString *)entityName;
{
    [self.observerInfo removeTarget:observer forKey:entityName];
}

- (void)removeObserver:(id)observer;
{    
    [self.observerInfo removeTarget:observer];
}

@end


@implementation BCCDataStoreControllerWorkParameters

- (id)init
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _workExecutionStyle = BCCDataStoreControllerWorkExecutionStyleMainMOCAndWait;
    
    _workBlock = NULL;
    _postSaveBlock = NULL;
    _shouldSave = YES;
    _executionDelay = 0.0f;
    
    return self;
}

@end


@implementation BCCDataStoreControllerImportParameters

@end


@implementation BCCDataStoreChangeNotification

- (id)initWithDictionary:(NSDictionary *)dictionary
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _updatedObjects = dictionary[NSUpdatedObjectsKey];
    _insertedObjects = dictionary[NSInsertedObjectsKey];
    _deletedObjects = dictionary[NSDeletedObjectsKey];
    
    return self;
}

@end


@implementation BCCDataStoreTargetAction

+ (BCCDataStoreTargetAction *)targetActionForKey:(NSString *)key withTarget:(id)target action:(SEL)action predicate:(NSPredicate *)predicate requiredChangedKeys:(NSArray *)changedKeys
{
    BCCDataStoreTargetAction *targetAction = (BCCDataStoreTargetAction *)[BCCDataStoreTargetAction targetActionForKey:key withTarget:target action:action];
    targetAction.predicate = predicate;
    targetAction.requiredChangedKeys = changedKeys;
    
    return targetAction;
}
@end
