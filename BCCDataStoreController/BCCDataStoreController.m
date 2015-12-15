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

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#elif TARGET_OS_MAC
#import <AppKit/AppKit.h>
#endif

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
- (NSSet *)managedObjects:(NSSet *)managedObjects withUpdatedKeys:(NSSet *)updatedKeys matchingRequiredChangeKeys:(NSArray *)requiredChangeKeys;
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

- (NSString *)cacheKeyForEntityName:(NSString *)entityName identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier;

@end


@interface BCCDataStoreTargetAction : BCCTargetAction

@property (nonatomic, retain) NSPredicate *predicate;
@property (nonatomic, retain) NSArray *requiredChangedKeys;

+ (BCCDataStoreTargetAction *)targetActionForKey:(NSString *)key withTarget:(id)target action:(SEL)action predicate:(NSPredicate *)predicate requiredChangedKeys:(NSArray *)changedKeys;

@end


#pragma mark -

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

- (NSString *)cacheKeyForEntityName:(NSString *)entityName identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier
{
    if (!identityValue || !groupIdentifier || !entityName) {
        return nil;
    }
    
    NSMutableString *keyString = [[NSMutableString alloc] initWithString:entityName];
    // TO DO: Force to string representation here
    [keyString appendFormat:@":%@", identityValue];
    
    if (groupIdentifier) {
        [keyString appendFormat:@":%@", groupIdentifier];
    }
    
    return [keyString BCC_MD5String];
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

#pragma mark - Accessors

- (void)setIdentifier:(NSString *)identifier
{
    if (![_identifier isEqualToString:identifier]) {
        [self deletePersistentStore];
    }
    
    _identifier = identifier;
    
    [self reset];
}

#pragma mark - Core Data State

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
        //[self.backgroundMOC performBlockAndWait:^{ }];
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
    
    // Remove persistent store and journal files
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
    
    NSPersistentStore *persistentStore = [coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:@{NSSQLitePragmasOption: @{@"journal_mode": @"WAL"}, NSMigratePersistentStoresAutomaticallyOption: @YES, NSInferMappingModelAutomaticallyOption: @YES} error:&error];
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
        BOOL success = [self.writeMOC save:&error];
        
        if (!success) {
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
        BOOL success = [managedObjectContext save:&error];
        
        if (!success) {
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

- (void)setCacheObject:(NSManagedObject *)cacheObject forMOC:(NSManagedObjectContext *)managedObjectContext identityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters
{
    NSString *entityName = identityParameters.entityName;
    NSString *identityPropertyName = identityParameters.identityPropertyName;
    NSString *groupPropertyName = identityParameters.groupPropertyName;
    
    if (!managedObjectContext || !cacheObject || !identityPropertyName) {
        return;
    }
    
    id identityValue = [cacheObject valueForKey:identityPropertyName];
    if (!identityValue) {
        return;
    }
    
    NSString *groupIdentifier = nil;
    if (groupPropertyName) {
        groupIdentifier = [cacheObject valueForKey:groupPropertyName];
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
    
    NSString *cacheKey = [self cacheKeyForEntityName:entityName identityValue:identityValue groupIdentifier:groupIdentifier];
    if (!cacheKey) {
        return;
    }
    
    [dictionaryForEntity setObject:cacheObject forKey:cacheKey];
}

- (NSManagedObject *)cacheObjectForMOC:(NSManagedObjectContext *)managedObjectContext identityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier
{
    NSString *entityName = identityParameters.entityName;
    
    if (!managedObjectContext || !entityName || !identityValue) {
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
    
    NSString *cacheKey = [self cacheKeyForEntityName:entityName identityValue:identityValue groupIdentifier:groupIdentifier];
    if (!cacheKey) {
        return nil;
    }
    
    NSManagedObject *object = [dictionaryForEntity objectForKey:cacheKey];
    return object;
}

- (void)removeCacheObjectForMOC:(NSManagedObjectContext *)managedObjectContext identityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier
{
    NSString *entityName = identityParameters.entityName;
    
    if (!managedObjectContext || !entityName) {
        return;
    }
    
    NSDictionary *objectCache = [self objectCacheForMOC:managedObjectContext];
    if (!objectCache) {
        return;
    }
    
    NSMutableDictionary *dictionaryForEntity = [objectCache objectForKey:entityName];
    if (!dictionaryForEntity) {
        return;
    }
    
    if (!identityValue) {
        [self setValue:[[NSMutableDictionary alloc] init] forKey:entityName];
        return;
    }
    
    NSString *cacheKey = [self cacheKeyForEntityName:entityName identityValue:identityValue groupIdentifier:groupIdentifier];
    if (!cacheKey) {
        return;
    }
    
    [dictionaryForEntity removeObjectForKey:cacheKey];
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
    
    NSMutableArray *keysToRemove = [[NSMutableArray alloc] init];
    
    [dictionaryForEntity enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        NSManagedObject *currentCacheObject = (NSManagedObject *)obj;
        
        if (currentCacheObject != affectedObject) {
            return;
        }
        
        [keysToRemove addObject:key];
    }];
    
    if (keysToRemove.count > 1) {
        [dictionaryForEntity removeObjectsForKeys:keysToRemove];
        [objectCache setValue:dictionaryForEntity forKey:entityName];
    }
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

- (NSManagedObject *)createAndInsertObjectWithIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier
{
    NSString *entityName = identityParameters.entityName;
    NSString *identityPropertyName = identityParameters.identityPropertyName;
    
    if (!entityName || !identityValue) {
        return nil;
    }
    
    NSManagedObject *createdObject = [self createAndInsertObjectWithEntityName:entityName];
    if (!createdObject) {
        return nil;
    }
    
    id normalizedIdentityValue = [self normalizedIdentityValueForValue:identityValue];
    if (!normalizedIdentityValue) {
        return nil;
    }
    
    [createdObject setValue:normalizedIdentityValue forKey:identityPropertyName];
    
    NSString *groupPropertyName = identityParameters.groupPropertyName;
    if (groupIdentifier && groupPropertyName) {
        [createdObject setValue:groupIdentifier forKey:groupPropertyName];
    }
    
    NSManagedObjectContext *moc = [self currentMOC];
    [self setCacheObject:createdObject forMOC:moc identityParameters:identityParameters];
    
    return createdObject;
}

- (NSManagedObject *)findOrCreateObjectWithIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier
{
    NSString *identityPropertyName = identityParameters.identityPropertyName;
    
    if (!identityPropertyName || !identityValue) {
        return nil;
    }
    
    id normalizedIdentityValue = [self normalizedIdentityValueForValue:identityValue];
    if (!normalizedIdentityValue) {
        return nil;
    }
    
    NSManagedObject *object = nil;
    NSManagedObjectContext *moc = [self currentMOC];
    
    object = [self cacheObjectForMOC:moc identityParameters:identityParameters identityValue:normalizedIdentityValue groupIdentifier:groupIdentifier];
    if (object) {
        return object;
    }
    
    NSMutableArray *propertyList = [[NSMutableArray alloc] initWithObjects:identityPropertyName, nil];
    NSMutableArray *valueList = [[NSMutableArray alloc] initWithObjects:normalizedIdentityValue, nil];
    
    NSString *groupPropertyName = identityParameters.groupPropertyName;
    
    if (groupIdentifier && groupPropertyName) {
        [propertyList addObject:groupPropertyName];
        [valueList addObject:groupIdentifier];
    }
    
    object = [self performSingleResultFetchForIdentityParameters:identityParameters identityValue:identityValue groupIdentifier:groupIdentifier error:NULL];
    if (object) {
        [self setCacheObject:object forMOC:moc identityParameters:identityParameters];
    } else {
        object = [self createAndInsertObjectWithIdentityParameters:identityParameters identityValue:identityValue groupIdentifier:groupIdentifier];
        if (!object) {
            return nil;
        }
    }
    
    return object;
}

- (void)deleteObjectWithIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier
{
    if (!identityParameters) {
        return;
    }
    
    id normalizedIdentityValue = [self normalizedIdentityValueForValue:identityValue];
    if (!normalizedIdentityValue) {
        return;
    }
    
    NSManagedObject *affectedObject = [self performSingleResultFetchForIdentityParameters:identityParameters identityValue:normalizedIdentityValue groupIdentifier:groupIdentifier error:NULL];
    if (!affectedObject) {
        return;
    }
    
    NSManagedObjectContext *moc = [self currentMOC];
    
    [self removeCacheObjectForMOC:moc identityParameters:identityParameters identityValue:normalizedIdentityValue groupIdentifier:groupIdentifier];
    
    [moc deleteObject:affectedObject];
}

- (void)deleteObjectsWithIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters groupIdentifier:(NSString *)groupIdentifer
{
    NSString *entityName = identityParameters.entityName;
    NSString *identityPropertyName = identityParameters.identityPropertyName;
    NSString *groupPropertyName = identityParameters.groupPropertyName;
    
    if (!entityName || !identityPropertyName || !groupPropertyName || !groupIdentifer) {
        return;
    }
    
    NSArray *affectedObjects = [self performFetchOfEntityWithName:entityName byProperty:groupPropertyName valueList:@[groupIdentifer] sortDescriptors:nil error:NULL];
    
    for (NSManagedObject *currentObject in affectedObjects) {
        NSManagedObjectContext *context = currentObject.managedObjectContext;
        
        id currentIDValue = [currentObject valueForKey:identityPropertyName];
        id normalizedIDValue = [self normalizedIdentityValueForValue:currentIDValue];
        [self removeCacheObjectForMOC:currentObject.managedObjectContext identityParameters:identityParameters identityValue:normalizedIDValue groupIdentifier:nil];
        
        [context deleteObject:currentObject];
    }
}

- (void)deleteObjectsWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName valueList:(NSArray *)valueList
 {
     if (!entityName || identityPropertyName || valueList.count < 1) {
         return;
     }
     
     NSArray *normalizedValueList = [self normalizedIdentityValueListForList:valueList];
     NSArray *objectList = [self performFetchOfEntityWithName:entityName byProperty:identityPropertyName valueList:normalizedValueList sortDescriptors:nil error:NULL];
     if (objectList.count < 1) {
         return;
     }
     
     BCCDataStoreControllerIdentityParameters *identityParameters = [[BCCDataStoreControllerIdentityParameters alloc] initWithEntityName:entityName];
     
     for (NSManagedObject *currentObject in objectList) {
         NSManagedObjectContext *context = currentObject.managedObjectContext;
         
         id currentIDValue = [currentObject valueForKey:identityPropertyName];
         id normalizedIDValue = [self normalizedIdentityValueForValue:currentIDValue];
         [self removeCacheObjectForMOC:currentObject.managedObjectContext identityParameters:identityParameters identityValue:normalizedIDValue groupIdentifier:nil];
         
         [context deleteObject:currentObject];
     }
}

- (void)deleteObjectsWithEntityName:(NSString *)entityName
{
    if (!entityName) {
        return;
    }
    
    NSManagedObjectContext *context = [self currentMOC];
    
    BCCDataStoreControllerIdentityParameters *identityParameters = [[BCCDataStoreControllerIdentityParameters alloc] initWithEntityName:entityName];
    [self removeCacheObjectForMOC:context identityParameters:identityParameters identityValue:nil groupIdentifier:nil];
    
    NSArray *objectsToDelete = [self objectsForEntityWithName:entityName sortDescriptors:nil];
    [objectsToDelete enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSManagedObject *currentObject = (NSManagedObject *)obj;
        [context deleteObject:currentObject];
    }];
}

- (void)deleteObjects:(NSArray *)affectedObjects
{
    for (NSManagedObject *currentObject in affectedObjects) {
        [self removeCacheObject:currentObject];
        [[self currentMOC] deleteObject:currentObject];
    }
}

#pragma mark - Query by Entity

- (NSArray *)objectsForEntityWithName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors
{
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName sortDescriptors:sortDescriptors];
    return [self performFetchRequest:fetchRequest error:NULL];
}

- (NSArray *)objectsForIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters groupIdentifier:(NSString *)groupIdentifier sortDescriptors:(NSArray *)sortDescriptors
{
    return [self objectsForIdentityParameters:identityParameters groupIdentifier:groupIdentifier filteredByProperty:nil valueSet:nil sortDescriptors:sortDescriptors];
}

- (NSArray *)objectsForIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters groupIdentifier:(NSString *)groupIdentifier filteredByProperty:(NSString *)propertyName valueSet:(NSSet *)valueSet sortDescriptors:(NSArray *)sortDescriptors
{
    if (!identityParameters.entityName) {
        return nil;
    }
    
    NSFetchRequest *fetchRequest = [self fetchRequestForIdentityParameters:identityParameters identityValue:nil groupIdentifier:groupIdentifier sortDescriptors:sortDescriptors];

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

#pragma mark - Fetching

- (NSManagedObject *)performSingleResultFetchForIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier error:(NSError **)error
{
    NSFetchRequest *fetchRequest = [self fetchRequestForIdentityParameters:identityParameters identityValue:identityValue groupIdentifier:groupIdentifier sortDescriptors:nil];
    return [self performSingleResultFetchRequest:fetchRequest error:error];
}

- (NSManagedObject *)performSingleResultFetchOfEntityWithName:(NSString *)entityName usingPropertyList:(NSArray *)propertyList valueList:(NSArray *)valueList error:(NSError **)error
{
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName usingPropertyList:propertyList valueList:valueList sortDescriptors:nil];
    if (!fetchRequest) {
        return nil;
    }
    
    return [self performSingleResultFetchRequest:fetchRequest error:error];
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

- (NSManagedObject *)performSingleResultFetchRequestWithTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary error:(NSError **)error
{
    NSFetchRequest *fetchRequest = [self fetchRequestForTemplateName:templateName substitutionDictionary:substitutionDictionary sortDescriptors:nil];
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
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName usingPropertyList:@[propertyName] valueList:valueList sortDescriptors:sortDescriptors];
    return [self performFetchRequest:fetchRequest error:error];
}

- (NSArray *)performFetchRequestWithTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary sortDescriptors:(NSArray *)sortDescriptors error:(NSError **)error
{
    NSFetchRequest *fetchRequest = [self fetchRequestForTemplateName:templateName substitutionDictionary:substitutionDictionary sortDescriptors:sortDescriptors];
    if (!fetchRequest) {
        return nil;
    }
    
    return [self performFetchRequest:fetchRequest error:error];
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

- (NSFetchRequest *)fetchRequestForIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier sortDescriptors:(NSArray *)sortDescriptors
{
    NSArray *identityValues = nil;
    if (identityValue) {
        identityValues = @[identityValue];
    }
    
    return [self fetchRequestForIdentityParameters:identityParameters identityValueList:identityValues groupIdentifier:groupIdentifier sortDescriptors:sortDescriptors];
}

- (NSFetchRequest *)fetchRequestForIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValueList:(NSArray *)identityValues groupIdentifier:(NSString *)groupIdentifier sortDescriptors:(NSArray *)sortDescriptors
{
    NSString *entityName = identityParameters.entityName;
    
    if (!entityName) {
        return nil;
    }
    
    NSString *identityPropertyName = identityParameters.identityPropertyName;

    NSMutableArray *propertyList = [[NSMutableArray alloc] init];
    NSMutableArray *valueList = [[NSMutableArray alloc] init];
    
    if (identityPropertyName && identityValues.count > 0) {
        [propertyList addObject:identityPropertyName];
        
        if (identityValues.count == 1) {
            [valueList addObject:identityValues[0]];
        } else if (identityValues.count > 0) {
            [valueList addObject:identityValues];
        }
    }

    NSString *groupPropertyName = identityParameters.groupPropertyName;
    
    if (groupPropertyName && groupIdentifier) {
        [propertyList addObject:groupPropertyName];
        [valueList addObject:groupIdentifier];
    }
    
    return [self fetchRequestForEntityName:entityName usingPropertyList:propertyList valueList:valueList sortDescriptors:sortDescriptors];
}

- (NSFetchRequest *)fetchRequestForEntityName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors
{
    if (!entityName) {
        return nil;
    }
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:entityName];
    fetchRequest.sortDescriptors = sortDescriptors;
    
    return fetchRequest;
}

- (NSFetchRequest *)fetchRequestForEntityName:(NSString *)entityName usingPropertyList:(NSArray *)propertyList valueList:(NSArray *)valueList sortDescriptors:(NSArray *)sortDescriptors
{
    if (!entityName) {
        return nil;
    }
    
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName sortDescriptors:sortDescriptors];
    
    if (propertyList.count > 0 && valueList.count > 0 && propertyList.count == valueList.count) {
        NSMutableArray *argumentArray = [[NSMutableArray alloc] init];
        NSMutableString *formatString = [[NSMutableString alloc] init];
        
        [propertyList enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            [argumentArray addObject:obj];
            [argumentArray addObject:valueList[idx]];
            
            NSString *predicateString = nil;
            
            if ([obj isKindOfClass:[NSArray class]]) {
                predicateString = @"(%K IN %@)";
            } else {
                predicateString = @"%K == %@";
            }
            
            [formatString BCC_appendPredicateCondition:predicateString];
        }];
        
        NSPredicate *predicate = [NSPredicate predicateWithFormat:formatString argumentArray:argumentArray];
        fetchRequest.predicate = predicate;
    }
    
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
    NSManagedObjectContext *context = changeNotification.object;
    
    NSSet *insertedObjects = [changeNotification.userInfo objectForKey:NSInsertedObjectsKey];
    NSSet *updatedObjects = [changeNotification.userInfo objectForKey:NSUpdatedObjectsKey];
    NSSet *deletedObjects = [changeNotification.userInfo objectForKey:NSDeletedObjectsKey];
    
    if (!context || (insertedObjects.count < 1 && updatedObjects.count < 1 && deletedObjects.count < 1)) {
        return;
    }
    
    NSDictionary *updatedKeysInfo = [context.userInfo objectForKey:BCCDataStoreControllerCurrentUpdatedKeysUserInfoKey];
    
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
            if (changedKeysRequired && ((matchingInsertedObjects.count < 1 && matchingUpdatedObjects.count < 1) || updatedKeysForCurrentEntity.count < 1)) {
                return;
            }
            
            // If we have required changed keys, examine the
            // predicate matched updated objects for ones
            // with changes matching the required keys
            if (changedKeysRequired) {
                NSSet *updatedObjectsMatchingChangedKeys = [self managedObjects:matchingUpdatedObjects withUpdatedKeys:updatedKeysForCurrentEntity matchingRequiredChangeKeys:currentRequiredChangedKeys];
                NSSet *insertedObjectsMatchingChangedKeys = [self managedObjects:matchingInsertedObjects withUpdatedKeys:updatedKeysForCurrentEntity matchingRequiredChangeKeys:currentRequiredChangedKeys];
                
                // If required changed keys were specified
                // but none were found, this target/action
                // is not a match
                if (insertedObjectsMatchingChangedKeys.count == 0 && updatedObjectsMatchingChangedKeys.count == 0) {
                    return;
                }
                
                if (insertedObjectsMatchingChangedKeys.count > 0) {
                    matchingInsertedObjects = insertedObjectsMatchingChangedKeys;
                }
                
                if (updatedObjectsMatchingChangedKeys.count > 0) {
                    matchingUpdatedObjects = updatedObjectsMatchingChangedKeys;
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
        
        [context.userInfo removeObjectForKey:BCCDataStoreControllerCurrentUpdatedKeysUserInfoKey];
    }
}

- (NSSet *)managedObjects:(NSSet *)managedObjects withUpdatedKeys:(NSSet *)updatedKeys matchingRequiredChangeKeys:(NSArray *)requiredChangeKeys
{
    NSMutableSet *managedObjectMatchingChangeKeys = [[NSMutableSet alloc] init];
    
    for (NSManagedObject *currentUpdatedObject in [managedObjects allObjects]) {
        for (NSString *currentChangedKey in updatedKeys) {
            NSUInteger foundIndex = [requiredChangeKeys indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
                NSString *currentRequiredChangedKey = (NSString *)obj;
                if ([currentRequiredChangedKey isEqualToString:currentChangedKey]){
                    *stop = YES;
                    return YES;
                }
                
                return NO;
            }];
            
            if (foundIndex != NSNotFound) {
                [managedObjectMatchingChangeKeys addObject:currentUpdatedObject];
            }
        }
    }
    
    return managedObjectMatchingChangeKeys;
}

- (NSDictionary *)updatedEntityKeysForMOC:(NSManagedObjectContext *)context
{
    if (!context) {
        return nil;
    }
    
    NSMutableSet *insertedOrUpdateObjects = [NSMutableSet new];
    [insertedOrUpdateObjects addObjectsFromArray:context.insertedObjects.allObjects];
    [insertedOrUpdateObjects addObjectsFromArray:context.updatedObjects.allObjects];
    
    if (!insertedOrUpdateObjects.count) {
        return nil;
    }
    
    NSMutableDictionary *changedEntitiesDictionary = [[NSMutableDictionary alloc] init];
    for (NSManagedObject *currentUpdatedObject in insertedOrUpdateObjects) {
        NSString *currentEntityName = currentUpdatedObject.entity.name;
        
        NSDictionary *currentObjectChangedValues = [currentUpdatedObject changedValues];
        NSEnumerator *changedKeysEnumerator = [currentObjectChangedValues keyEnumerator];
        for (NSString *currentChangedKey in changedKeysEnumerator) {
            NSMutableSet *changedKeysListForEntity = [changedEntitiesDictionary objectForKey:currentEntityName];
            if (!changedKeysListForEntity) {
                changedKeysListForEntity = [[NSMutableSet alloc] init];
                [changedEntitiesDictionary setObject:changedKeysListForEntity forKey:currentEntityName];
            }
            
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

#pragma mark -

@implementation BCCDataStoreController (JSONSupport)

- (NSArray *)createObjectsFromJSONArray:(NSArray *)dictionaryArray usingImportParameters:(BCCDataStoreControllerImportParameters *)importParameters identityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters
{
    NSString *groupPropertyName = identityParameters.groupPropertyName;
    NSString *listIndexPropertyName = identityParameters.listIndexPropertyName;
    NSString *groupIdentifier = importParameters.groupIdentifier;
    NSString *dictionaryIdentityPropertyName = importParameters.dictionaryIdentityPropertyName;
    BOOL findExisting = importParameters.findExisting;
    BOOL deleteExisting = importParameters.deleteExisting;
    
    if (!dictionaryArray || dictionaryArray.count < 1) {
        return nil;
    }
    
    NSManagedObjectContext *managedObjectContext = [self currentMOC];
    
    if (importParameters.deleteExisting && groupPropertyName && groupIdentifier) {
        [self deleteObjectsWithIdentityParameters:identityParameters groupIdentifier:groupIdentifier];
    }
    
    NSMutableArray *affectedObjects = [[NSMutableArray alloc] init];
    
    [dictionaryArray enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSDictionary *currentDictionary = (NSDictionary *)obj;
        
        NSManagedObject *affectedObject = nil;
        id identityValue = [currentDictionary valueForKeyPath:dictionaryIdentityPropertyName];
        if (!identityValue && findExisting) {
            return;
        }
        
        if (findExisting && !deleteExisting) {
            affectedObject = [self findOrCreateObjectWithIdentityParameters:identityParameters identityValue:identityValue groupIdentifier:groupIdentifier];
        } else if (identityValue) {
            affectedObject = [self createAndInsertObjectWithIdentityParameters:identityParameters identityValue:identityValue groupIdentifier:groupIdentifier];
        }
        
        if (!affectedObject) {
            return;
        }
        
        if (listIndexPropertyName) {
            [affectedObject setValue:@(idx) forKey:listIndexPropertyName];
        }
        
        if (importParameters.postCreateBlock) {
            importParameters.postCreateBlock(affectedObject, currentDictionary, idx, managedObjectContext);
        }
        
        [affectedObjects addObject:affectedObject];
        
    }];
    
    return affectedObjects;
}

@end

#pragma mark -

@implementation BCCDataStoreControllerIdentityParameters

#pragma mark - Class Methods

+ (instancetype)identityParametersWithEntityName:(NSString *)entityName identityPropertyName:(NSString *)identityPropertyName
{
    BCCDataStoreControllerIdentityParameters *identityParameters = [[BCCDataStoreControllerIdentityParameters alloc] initWithEntityName:entityName];
    identityParameters.identityPropertyName = identityPropertyName;
    
    return identityParameters;
}

+ (instancetype)identityParametersWithEntityName:(NSString *)entityName groupPropertyName:(NSString *)groupPropertyName
{
    BCCDataStoreControllerIdentityParameters *identityParameters = [[BCCDataStoreControllerIdentityParameters alloc] initWithEntityName:entityName];
    identityParameters.groupPropertyName = groupPropertyName;
    
    return identityParameters;
}

#pragma mark - Initialization

- (instancetype)initWithEntityName:(NSString *)entityName
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _entityName = entityName;
    
    return self;
}

#pragma mark - Accessors

- (BOOL)isValidForQuery
{
    return (_entityName != nil && _identityPropertyName != nil);
}

@end

#pragma mark -

@implementation BCCDataStoreControllerWorkParameters

#pragma mark - Initialization

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

#pragma mark -

@implementation BCCDataStoreControllerImportParameters

@end

#pragma mark -

@implementation BCCDataStoreChangeNotification

#pragma mark - Initialization

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

- (NSString *)description
{
    return [[super description] stringByAppendingFormat:@"\nUpdated Objects: %lu\nInserted Objects: %lu\nDeleted Objects: %lu", (unsigned long)_updatedObjects.count, (unsigned long)_insertedObjects.count, (unsigned long)_deletedObjects.count];
}

@end

#pragma mark -

@implementation BCCDataStoreTargetAction

#pragma mark - Class Methods

+ (BCCDataStoreTargetAction *)targetActionForKey:(NSString *)key withTarget:(id)target action:(SEL)action predicate:(NSPredicate *)predicate requiredChangedKeys:(NSArray *)changedKeys
{
    BCCDataStoreTargetAction *targetAction = (BCCDataStoreTargetAction *)[BCCDataStoreTargetAction targetActionForKey:key withTarget:target action:action];
    targetAction.predicate = predicate;
    targetAction.requiredChangedKeys = changedKeys;
    
    return targetAction;
}

@end

#pragma mark -

@implementation BCCDataStoreController (Deprecated)

#pragma mark - Worker Queue Object Cache

- (void)setCacheObject:(NSManagedObject *)cacheObject forMOC:(NSManagedObjectContext *)managedObjectContext entityName:(NSString *)entityName identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier
{
    if (!managedObjectContext || !cacheObject || !entityName || !identityValue) {
        return;
    }
    
    BCCDataStoreControllerIdentityParameters *identityParameters = [[BCCDataStoreControllerIdentityParameters alloc] initWithEntityName:entityName];
    [self setCacheObject:cacheObject forMOC:managedObjectContext identityParameters:identityParameters];
}

- (NSManagedObject *)cacheObjectForMOC:(NSManagedObjectContext *)managedObjectContext entityName:(NSString *)entityName identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier
{
    if (!managedObjectContext || !entityName || !identityValue) {
        return nil;
    }
    
    BCCDataStoreControllerIdentityParameters *identityParameters = [[BCCDataStoreControllerIdentityParameters alloc] initWithEntityName:entityName];
    return [self cacheObjectForMOC:managedObjectContext identityParameters:identityParameters identityValue:identityValue groupIdentifier:groupIdentifier];
}

- (void)removeCacheObjectForMOC:(NSManagedObjectContext *)managedObjectContext entityName:(NSString *)entityName identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier
{
    if (!managedObjectContext || !entityName || !identityValue) {
        return;
    }
    
    BCCDataStoreControllerIdentityParameters *identityParameters = [[BCCDataStoreControllerIdentityParameters alloc] initWithEntityName:entityName];
    [self removeCacheObjectForMOC:managedObjectContext identityParameters:identityParameters identityValue:identityValue groupIdentifier:groupIdentifier];
}

#pragma mark - Entity CRUD

- (NSManagedObject *)createAndInsertObjectWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier
{
    BCCDataStoreControllerIdentityParameters *identityParams = [BCCDataStoreControllerIdentityParameters identityParametersWithEntityName:entityName identityPropertyName:identityPropertyName];
    identityParams.groupPropertyName = groupPropertyName;
    
    return [self createAndInsertObjectWithIdentityParameters:identityParams identityValue:identityValue groupIdentifier:groupIdentifier];
}

- (NSManagedObject *)findOrCreateObjectWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier
{
    BCCDataStoreControllerIdentityParameters *identityParams = [BCCDataStoreControllerIdentityParameters identityParametersWithEntityName:entityName identityPropertyName:identityPropertyName];
    identityParams.groupPropertyName = groupPropertyName;
    
    return [self findOrCreateObjectWithIdentityParameters:identityParams identityValue:identityValue groupIdentifier:groupIdentifier];
}

- (NSArray *)createObjectsOfEntityType:(NSString *)entityName fromDictionaryArray:(NSArray *)dictionaryArray findExisting:(BOOL)findExisting dictionaryIdentityProperty:(NSString *)dictionaryIdentityPropertyName modelIdentityProperty:(NSString *)modelIdentityPropertyName groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier postCreateBlock:(BCCDataStoreControllerPostCreateBlock)postCreateBlock
{
    BCCDataStoreControllerIdentityParameters *identityParameters = [BCCDataStoreControllerIdentityParameters identityParametersWithEntityName:entityName identityPropertyName:modelIdentityPropertyName];
    identityParameters.groupPropertyName = groupPropertyName;
    
    BCCDataStoreControllerImportParameters *importParameters = [[BCCDataStoreControllerImportParameters alloc] init];
    importParameters.groupIdentifier = groupIdentifier;
    importParameters.dictionaryIdentityPropertyName = dictionaryIdentityPropertyName;
    importParameters.findExisting = findExisting;
    
    importParameters.postCreateBlock = postCreateBlock;
    
    return [self createObjectsFromJSONArray:dictionaryArray usingImportParameters:importParameters identityParameters:identityParameters];
}

- (void)deleteObjectsWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier
{
    BCCDataStoreControllerIdentityParameters *identityParameters = [BCCDataStoreControllerIdentityParameters identityParametersWithEntityName:entityName identityPropertyName:identityPropertyName];
    identityParameters.groupPropertyName = groupPropertyName;
    
    BCCDataStoreControllerImportParameters *importParameters = [[BCCDataStoreControllerImportParameters alloc] init];
    importParameters.groupIdentifier = groupIdentifier;
    
    NSArray *affectedObjects = [self performFetchOfEntityWithName:entityName usingPropertyList:@[identityPropertyName, groupPropertyName] valueList:@[identityValue, groupIdentifier] sortDescriptors:nil error:NULL];
    
    for (NSManagedObject *currentObject in affectedObjects) {
        NSManagedObjectContext *context = currentObject.managedObjectContext;
        
        [self removeCacheObjectForMOC:context identityParameters:identityParameters identityValue:identityValue groupIdentifier:groupIdentifier];
        
        [context deleteObject:currentObject];
    }
}

#pragma mark - Query by Entity

- (NSArray *)objectsForEntityWithName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier
{
    BCCDataStoreControllerIdentityParameters *identityParameters = [BCCDataStoreControllerIdentityParameters identityParametersWithEntityName:entityName identityPropertyName:nil];
    identityParameters.groupPropertyName = groupPropertyName;
    
    return [self objectsForIdentityParameters:identityParameters groupIdentifier:groupIdentifier sortDescriptors:sortDescriptors];
}

- (NSArray *)objectsForEntityWithName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier filteredByProperty:(NSString *)propertyName valueSet:(NSSet *)valueSet
{
    BCCDataStoreControllerIdentityParameters *identityParameters = [BCCDataStoreControllerIdentityParameters identityParametersWithEntityName:entityName identityPropertyName:nil];
    identityParameters.groupPropertyName = groupPropertyName;
    
    return [self objectsForIdentityParameters:identityParameters groupIdentifier:groupIdentifier filteredByProperty:propertyName valueSet:valueSet sortDescriptors:sortDescriptors];
}

@end
