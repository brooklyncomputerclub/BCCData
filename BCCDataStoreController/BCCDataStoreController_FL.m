//
//  BCCDataStoreController.m
//
//  Created by Buzz Andersen on 3/24/11.
//  Copyright 2013 Brooklyn Computer Club. All rights reserved.
//

#import "BCCDataStoreController.h"
#import "BCCTargetActionQueue.h"
#import "NSFileManager+BCCAdditions.h"

NSString * const kBCCDataStoreControllerThreadContextKey = @"kBCCDataStoreControllerThreadContextKey";

// Notifications
NSString *BCCDataStoreControllerWillClearDatabaseNotification = @"BCCDataStoreControllerWillClearDatabaseNotification";
NSString *BCCDataStoreControllerDidClearDatabaseNotification = @"BCCDataStoreControllerDidClearDatabaseNotification";

NSString *BCCDataStoreControllerCurrentUpdatedKeysUserInfoKey = @"BCCDataStoreControllerCurrentUpdatedKeysUserInfoKey";
NSString *BCCDataStoreControllerContextObjectCacheUserInfoKey = @"BCCDataStoreControllerContextObjectCacheUserInfoKey";

NSString *BCCDataStoreControllerWillClearIncompatibleDatabaseNotification = @"BCCDataStoreControllerWillClearIncompatibleDatabaseNotification";
NSString *BCCDataStoreControllerDidClearIncompatibleDatabaseNotification = @"BCCDataStoreControllerDidClearIncompatibleDatabaseNotification";


@interface BCCDataStoreController ()

@property (strong, nonatomic) NSString *identifier;
@property (strong, nonatomic) NSString *rootDirectory;
@property (strong, nonatomic) NSString *persistentStorePath;

@property (strong, nonatomic) NSManagedObjectModel *managedObjectModel;
@property (strong, nonatomic) NSPersistentStoreCoordinator *persistentStoreCoordinator;

@property (strong, nonatomic) NSManagedObjectContext *writeContext;
@property (strong, nonatomic) NSManagedObjectContext *mainContext;
@property (strong, nonatomic) NSManagedObjectContext *backgroundContext;

@property (strong, nonatomic) dispatch_queue_t workerQueue;

@property (strong, nonatomic) BCCTargetActionQueue *observerInfo;

@property (nonatomic) Class identityClass;

// Core Data Stack Management
- (void)initializeCoreDataStack;
- (void)resetCoreDataStack;

// Saving
- (void)saveWriteContext;
- (void)saveContext:(NSManagedObjectContext *)context;

// Change Notifications
- (NSDictionary *)updatedEntityKeysForContext:(NSManagedObjectContext *)context;
- (void)notifyObserversForChangeNotification:(NSNotification *)changeNotification;

// Worker Context Object Caches
- (NSMutableDictionary *)objectCacheForContext:(NSManagedObjectContext *)context;

// Identity
- (id)normalizedIdentityValueForValue:(id)value;
- (NSArray *)normalizedIdentityValueListForList:(NSArray *)valueList;
- (NSSet *)normalizedIdentityValueSetForSet:(NSSet *)valueSet;

// Work Queueing
- (void)performBlock:(BCCDataStoreControllerWorkBlock)block onContext:(NSManagedObjectContext *)context andWait:(BOOL)wait withSave:(BOOL)save;

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

- (id)initWithIdentifier:(NSString *)identifier rootDirectory:(NSString *)rootDirectory
{
    if (!(self = [self initWithIdentifier:identifier rootDirectory:rootDirectory modelPath:nil])) {
        return nil;
    }
    
    return self;
}

- (id)initWithIdentifier:(NSString *)identifier rootDirectory:(NSString *)rootDirectory modelPath:(NSString *)modelPath
{
    if (!(self = [super init])) {
        return nil;
    }

    _identifier = identifier;
    
    _rootDirectory = rootDirectory;
    
    _managedObjectModelPath = modelPath;
    
    _workerQueue = NULL;
    
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveMainContext) name:UIApplicationWillTerminateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveMainContext) name:UIApplicationWillResignActiveNotification object:nil];
#elif TARGET_OS_MAC
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveMainContext) name:NSApplicationWillTerminateNotification object:nil];
#endif
    
    [self initializeCoreDataStack];
    
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // This will release the main context, managed object model, and
    // persistent store coordinator
    [self reset];
}

#pragma mark Core Data State

- (void)initializeCoreDataStack
{
    if (!self.managedObjectModelPath || ![[NSFileManager defaultManager] fileExistsAtPath:self.managedObjectModelPath isDirectory:NULL]) {
        NSLog(@"Unable to locate managed object model at path: %@", self.managedObjectModelPath);
        return;
    }
    
    // Set up the managed object model
    NSURL *modelURL = [NSURL fileURLWithPath:self.managedObjectModelPath];
    self.managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    
    // Set up the persistent store coordinator
    if (!self.rootDirectory) {
        self.rootDirectory = [[self class] defaultRootDirectory];
    }
    
    if (!self.identifier) {
        self.identifier = NSStringFromClass([self class]);
    }
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.rootDirectory]) {
        [[NSFileManager defaultManager] BCC_recursivelyCreatePath:self.rootDirectory];
    }
    
    NSPersistentStoreCoordinator *psc = [self newPersistentStoreCoordinatorModel:self.managedObjectModel path:self.persistentStorePath];
    
    // Set up the write context
    NSManagedObjectContext *writeContext = [self newManagedObjectContextWithConcurrencyType:NSMainQueueConcurrencyType];
    self.writeContext = writeContext;
    [self.writeContext performBlockAndWait:^{
        writeContext.persistentStoreCoordinator = psc;
        writeContext.mergePolicy = NSOverwriteMergePolicy;
    }];
    
    // Set up main thread context (for querying)
    NSManagedObjectContext *mainContext = [self newManagedObjectContextWithConcurrencyType:NSMainQueueConcurrencyType];
    self.mainContext = mainContext;
    [self.mainContext performBlockAndWait:^{
        mainContext.parentContext = writeContext;
        mainContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy;
    }];
    
    // Set up background private queue context
    NSManagedObjectContext *backgroundContext = [self newManagedObjectContextWithConcurrencyType:NSPrivateQueueConcurrencyType];
    self.backgroundContext = backgroundContext;
    [backgroundContext performBlockAndWait:^{
        backgroundContext.parentContext = mainContext;
    }];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mainContextDidSave:) name:NSManagedObjectContextDidSaveNotification object:mainContext];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(backgroundContextDidSave:) name:NSManagedObjectContextDidSaveNotification object:backgroundContext];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mainContextWillSave:) name:NSManagedObjectContextWillSaveNotification object:mainContext];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(backgroundContextWillSave:) name:NSManagedObjectContextWillSaveNotification object:backgroundContext];
    
    // Set up worker queue
    NSString *workerName = [NSString stringWithFormat:@"com.brooklyncomputerclub.%@.WorkerQueue", NSStringFromClass([self class])];
    _workerQueue = dispatch_queue_create([workerName UTF8String], DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(_workerQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    
    // Set up observation info
    self.observerInfo = [[BCCTargetActionQueue alloc] init];

    self.identityClass = [NSString class];
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
    
    if (_backgroundContext) {
        [self.backgroundContext performBlockAndWait:^{ }];
        _backgroundContext = nil;
    }
    
    if (_mainContext) {
        [self.mainContext performBlockAndWait:^{ }];
        _mainContext = nil;
    }
    
    if (_writeContext) {
        [self.writeContext performBlockAndWait:^{ }];
        _writeContext = nil;
    }
    
    _managedObjectModel = nil;
    
    _persistentStoreCoordinator = nil;
}

- (void)deletePersistentStore
{
    // Clear out Core Data stack
    [self resetCoreDataStack];
    
    NSString *rootDirectory = self.rootDirectory;
    if (!rootDirectory.length) {
        return;
    }
    
    // Remove persistent store & journal files
    [[NSNotificationCenter defaultCenter] postNotificationName:BCCDataStoreControllerWillClearDatabaseNotification object:self];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *files = [fileManager contentsOfDirectoryAtPath:rootDirectory error:NULL];
    for (NSString *file in files) {
        [fileManager removeItemAtPath:[rootDirectory stringByAppendingPathComponent:file] error:NULL];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:BCCDataStoreControllerDidClearDatabaseNotification object:self];
    
    [self initializeCoreDataStack];
}

#pragma mark - Accessors

- (NSString *)persistentStorePath
{
    if (!self.rootDirectory || !self.identifier) {
        return nil;
    }
    
    return [self.rootDirectory stringByAppendingPathComponent:[self.identifier stringByAppendingPathExtension:@"sqlite"]];
}

#pragma mark - Persistent Store Coordinators

- (NSPersistentStoreCoordinator *)newPersistentStoreCoordinatorModel:(NSManagedObjectModel *)model path:(NSString *)path
{
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    
    NSURL *storeURL = [NSURL fileURLWithPath:path];
    
    NSError *error = nil;
    if (![coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:@{NSSQLitePragmasOption: @{@"journal_mode": @"WAL"}, NSMigratePersistentStoresAutomaticallyOption: @YES, NSInferMappingModelAutomaticallyOption: @YES} error:&error]) {
        
        [[NSNotificationCenter defaultCenter] postNotificationName:BCCDataStoreControllerWillClearIncompatibleDatabaseNotification object:self];
        
        // If we couldn't load the persistent store (likely due to database incompatibility)
        // delete the existing database and try again.
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        
        if (![coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:nil error:&error]) {
            NSLog(@"Could not load database after clearing! Error: %@, %@", error, [error userInfo]);
            exit(1);
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:BCCDataStoreControllerDidClearIncompatibleDatabaseNotification object:self];
    }
    
    return coordinator;
}

#pragma mark - Managed Object Contexts

- (NSManagedObjectContext *)newManagedObjectContextWithConcurrencyType:(NSManagedObjectContextConcurrencyType)concurrencyType
{
    NSManagedObjectContext *newContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:concurrencyType];
    
    newContext.undoManager = nil;
    
    [newContext.userInfo setObject:[[NSMutableDictionary alloc] init] forKey:BCCDataStoreControllerContextObjectCacheUserInfoKey];
    
    return newContext;
}

- (NSManagedObjectContext *)currentContext
{
    if (![[NSThread currentThread] isMainThread]) {
        return self.backgroundContext;
    }
    
    return self.mainContext;
}

- (NSManagedObjectContext *)threadContext
{
    if ([[NSThread currentThread] isMainThread]) {
        return self.mainContext;
    }
    
    NSThread *currentThread = [NSThread currentThread];
    NSManagedObjectContext *threadContext = [currentThread.threadDictionary valueForKey:kBCCDataStoreControllerThreadContextKey];
    
    // Check if this context is a remnant from a previous session
    if (threadContext.parentContext != self.backgroundContext) {
        [currentThread.threadDictionary removeObjectForKey:kBCCDataStoreControllerThreadContextKey];
        threadContext = nil;
    }
    
    if (!threadContext) {
        threadContext = [self newManagedObjectContextWithConcurrencyType:NSPrivateQueueConcurrencyType];
        [threadContext performBlockAndWait:^{
            threadContext.parentContext = self.backgroundContext;
        }];
        [currentThread.threadDictionary setValue:threadContext forKey:kBCCDataStoreControllerThreadContextKey];
    }
    
    return threadContext;
}

#pragma mark - Saving

- (void)saveCurrentContext
{
    NSManagedObjectContext *currentContext = [self currentContext];
    [self saveContext:currentContext];
}

- (void)saveWriteContext
{
    [self.writeContext performBlockAndWait:^{
        NSError *error = nil;
        BOOL success = [self.writeContext save:&error];
        
        if (!success) {
            NSLog(@"BCCDataStoreController Write Context Save Exception: %@", error);
            return;
        }
    }];
}

- (void)saveMainContext
{
    [self saveContext:self.mainContext];
}

- (void)saveBackgroundContext
{
    [self saveContext:self.backgroundContext];
}

- (void)saveContext:(NSManagedObjectContext *)context
{
    if (!context) {
        return;
    }
    
    void (^saveBlock)(void) = ^{
        NSError *error = nil;
        BOOL success = [context save:&error];
        
        if (!success) {
            NSLog(@"BCCDataStoreController Context Save Exception: %@", error);
            return;
        }
    };
    
    if (context.concurrencyType == NSPrivateQueueConcurrencyType || context.concurrencyType == NSMainQueueConcurrencyType) {
        [context performBlockAndWait:saveBlock];
    } else {
        saveBlock();
    }
}

#pragma mark - Save Notifications

- (void)backgroundContextWillSave:(NSNotification *)notification
{
    NSManagedObjectContext *changedContext = notification.object;
    if (changedContext != self.backgroundContext) {
        return;
    }
    
    NSDictionary *updatedKeysInfo = [self updatedEntityKeysForContext:changedContext];
    if (updatedKeysInfo) {
        [changedContext.userInfo setObject:updatedKeysInfo forKey:BCCDataStoreControllerCurrentUpdatedKeysUserInfoKey];
    }
}

- (void)mainContextWillSave:(NSNotification *)notification
{
    NSManagedObjectContext *changedContext = notification.object;
    if (changedContext != self.mainContext) {
        return;
    }
    
    NSDictionary *updatedKeysInfo = [self updatedEntityKeysForContext:changedContext];
    if (updatedKeysInfo) {
        [changedContext.userInfo setObject:updatedKeysInfo forKey:BCCDataStoreControllerCurrentUpdatedKeysUserInfoKey];
    }
}

- (void)backgroundContextDidSave:(NSNotification *)notification
{
    NSManagedObjectContext *changedContext = notification.object;
    if (changedContext != self.backgroundContext) {
        return;
    }
    
    [self saveMainContext];
}

- (void)mainContextDidSave:(NSNotification *)notification
{
    NSManagedObjectContext *changedContext = notification.object;
    if (changedContext != self.mainContext) {
        return;
    }

    [self saveWriteContext];
    
    [self.mainContext performBlockAndWait:^{
        [self notifyObserversForChangeNotification:notification];
    }];
}

#pragma mark - Queue Management

- (void)performBlockOnMainContext:(BCCDataStoreControllerWorkBlock)block
{
    [self performBlock:block onContext:self.mainContext andWait:NO withSave:YES];
}

- (void)performBlockOnMainContextAndWait:(BCCDataStoreControllerWorkBlock)block
{
    [self performBlock:block onContext:self.mainContext andWait:YES withSave:YES];
}

- (void)performBlockOnMainContext:(BCCDataStoreControllerWorkBlock)block afterDelay:(NSTimeInterval)delay
{
    if (!block) {
        return;
    }
    
    if (delay) {
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC);
        dispatch_after(popTime, self.workerQueue, ^{
            [self performBlockOnMainContext:block];
        });
    } else {
        [self performBlockOnMainContext:block];
    }
}

- (void)performBlockOnBackgroundContext:(BCCDataStoreControllerWorkBlock)block
{
    [self performBlock:block onContext:self.backgroundContext andWait:NO withSave:YES];
}

- (void)performBlockOnBackgroundContextAndWait:(BCCDataStoreControllerWorkBlock)block
{
    [self performBlock:block onContext:self.backgroundContext andWait:YES withSave:YES];
}

- (void)performBlockOnBackgroundContext:(BCCDataStoreControllerWorkBlock)block afterDelay:(NSTimeInterval)delay
{
    if (!block) {
        return;
    }
    
    if (delay) {
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC);
        dispatch_after(popTime, self.workerQueue, ^{
            [self performBlockOnBackgroundContext:block];
        });
    } else {
        [self performBlockOnBackgroundContext:block];
    }
}

- (void)performBlockOnThreadContext:(BCCDataStoreControllerWorkBlock)block
{
    [self performBlock:block onContext:[self threadContext] andWait:NO withSave:NO];
}

- (void)performBlockOnThreadContextAndWait:(BCCDataStoreControllerWorkBlock)block
{
    [self performBlock:block onContext:[self threadContext] andWait:YES withSave:NO];
}

- (void)performBlock:(BCCDataStoreControllerWorkBlock)block onContext:(NSManagedObjectContext *)context andWait:(BOOL)wait withSave:(BOOL)save
{
    if (!context || !block) {
        return;
    }
    
    void (^workBlock)(void) = ^(void) {
        block(self, context);
        
        if (save) {
            [self saveContext:context];
        }

        NSMutableDictionary *contextObjectCache = [self objectCacheForContext:context];
        if (contextObjectCache) {
            [contextObjectCache removeAllObjects];
        }
    };
    
    if (context.concurrencyType == NSMainQueueConcurrencyType || context.concurrencyType == NSPrivateQueueConcurrencyType) {
        wait ? [context performBlockAndWait:workBlock] : [context performBlock:workBlock];
    } else {
        workBlock();
    }
}

#pragma mark - Worker Queue Object Cache

- (void)setCacheObject:(NSManagedObject *)cacheObject forContext:(NSManagedObjectContext *)context entityName:(NSString *)entityName identifier:(NSString *)identifier
{
    if (!cacheObject || !entityName || !identifier) {
        return;
    }
    
    NSMutableDictionary *objectCache = [self objectCacheForContext:context];
    if (!objectCache) {
        return;
    }

    NSMutableDictionary *dictionaryForEntity = [objectCache objectForKey:entityName];
    if (!dictionaryForEntity) {
        dictionaryForEntity = [[NSMutableDictionary alloc] init];
        [objectCache setObject:dictionaryForEntity forKey:entityName];
    }
    
    [dictionaryForEntity setObject:cacheObject forKey:identifier];
}

- (NSManagedObject *)cacheObjectForContext:(NSManagedObjectContext *)context entityName:(NSString *)entityName identifier:(NSString *)identifier
{
    if (!entityName || !identifier) {
        return nil;
    }
    
    NSDictionary *objectCache = [self objectCacheForContext:context];
    if (!objectCache) {
        return nil;
    }
    
    NSDictionary *dictionaryForEntity = [objectCache objectForKey:entityName];
    if (!dictionaryForEntity) {
        return nil;
    }
    
    NSManagedObject *object = [dictionaryForEntity objectForKey:identifier];    
    return object;
}

- (void)removeCacheObjectForEntityNameForContext:(NSManagedObjectContext *)context entityName:(NSString *)entityName identifier:(NSString *)identifier
{
    NSDictionary *objectCache = [self objectCacheForContext:context];
    if (!objectCache) {
        return;
    }
    
    NSMutableDictionary *dictionaryForEntity = [objectCache objectForKey:entityName];
    if (!dictionaryForEntity) {
        return;
    }
    
    [dictionaryForEntity removeObjectForKey:identifier];
}

- (void)clearObjectCacheForContext:(NSManagedObjectContext *)context
{
    NSMutableDictionary *objectCache = [self objectCacheForContext:context];
    if (!objectCache) {
        return;
    }
    
    [objectCache removeAllObjects];
}

- (NSMutableDictionary *)objectCacheForContext:(NSManagedObjectContext *)context
{
    if (!context) {
        return nil;
    }
    
    return [context.userInfo objectForKey:BCCDataStoreControllerContextObjectCacheUserInfoKey];
}

#pragma mark - Entity CRUD

- (NSManagedObject *)createAndInsertObjectWithEntityName:(NSString *)entityName
{
    if (!entityName) {
        return nil;
    }
    
    NSManagedObjectContext *context = [self currentContext];
    
    NSEntityDescription *entity = [NSEntityDescription entityForName:entityName inManagedObjectContext:context];
    if (!entity) {
        return nil;
    }
    
    NSManagedObject *createdObject = [[NSClassFromString([entity managedObjectClassName]) alloc] initWithEntity:entity insertIntoManagedObjectContext:context];
    
    return createdObject;
}

- (NSManagedObject *)createAndInsertObjectWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue
{
    if (!identityPropertyName || !identityValue) {
        return nil;
    }
    
    NSManagedObject *createdObject = [self createAndInsertObjectWithEntityName:entityName];
    if (!createdObject) {
        return nil;
    }

    id normalizedIdentityValue = [self normalizedIdentityValueForValue:identityValue];
    [createdObject setValue:normalizedIdentityValue forKey:identityPropertyName];

    [self setCacheObject:createdObject forContext:[self currentContext] entityName:entityName identifier:normalizedIdentityValue];

    return createdObject;
}

- (NSManagedObject *)findOrCreateObjectWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue
{
    if (!entityName || !identityPropertyName || !identityValue) {
        return nil;
    }
    
    id normalizedIdentityValue = [self normalizedIdentityValueForValue:identityValue];
    if (!normalizedIdentityValue) {
        return nil;
    }
    
    NSManagedObject *object = nil;
    NSManagedObjectContext *context = [self currentContext];
    
    object = [self cacheObjectForContext:context entityName:entityName identifier:normalizedIdentityValue];
    if (object) {
        return object;
    }
    
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName byProperty:identityPropertyName value:normalizedIdentityValue sortDescriptors:nil];
    
    object = [self performSingleResultFetchRequest:fetchRequest error:NULL];
    if (!object) {
        object = [self createAndInsertObjectWithEntityName:entityName identityProperty:identityPropertyName identityValue:identityValue];
        if (!object) {
            return nil;
        }
    }
    
    return object;
}

- (NSArray *)createObjectsOfEntityType:(NSString *)entityName fromDictionaryArray:(NSArray *)dictionaryArray findExisting:(BOOL)findExisting dictionaryIdentityProperty:(NSString *)dictionaryIdentityPropertyName modelIdentityProperty:(NSString *)modelIdentityPropertyName postCreateBlock:(BCCDataStoreControllerPostCreateBlock)postCreateBlock
{
    if (!entityName || !dictionaryArray || dictionaryArray.count < 1) {
        return nil;
    }

    NSManagedObjectContext *context = [self currentContext];
    
    NSMutableArray *affectedObjects = [[NSMutableArray alloc] init];
    
    for (NSDictionary *currentDictionary in dictionaryArray) {
        NSManagedObject *affectedObject = nil;
        id identifier = [currentDictionary objectForKey:dictionaryIdentityPropertyName];
        if (!identifier) {
            continue;
        }
        
        if (findExisting) {
            affectedObject = [self findOrCreateObjectWithEntityName:entityName identityProperty:modelIdentityPropertyName identityValue:identifier];
        } else {
            affectedObject = [self createAndInsertObjectWithEntityName:entityName identityProperty:modelIdentityPropertyName identityValue:identifier];
        }
        
        if (!affectedObject) {
            continue;
        }
        
        if (postCreateBlock) {
            postCreateBlock(affectedObject, currentDictionary, context);
        }
        
        [affectedObjects addObject:affectedObject];
    }
    
    return affectedObjects;
}

- (void)deleteObjectsWithEntityName:(NSString *)entityName
{
    if (!entityName) {
        return;
    }
    
    [self deleteObjectsWithEntityName:entityName identityProperty:nil identityValue:nil];
}

- (void)deleteObjectsWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue;
{
    if (!entityName || (identityPropertyName && !identityValue)) {
        return;
    }
    
    NSArray *affectedObjects = [self performFetchOfEntityWithName:entityName byProperty:identityPropertyName value:identityValue sortDescriptors:nil error:NULL];
    if (affectedObjects.count < 1) {
        return;
    }

    id normalizedIdentityValue = [self normalizedIdentityValueForValue:identityValue];
    
    for (NSManagedObject *currentObject in affectedObjects) {
        [self removeCacheObjectForEntityNameForContext:[self currentContext] entityName:entityName identifier:normalizedIdentityValue];
        [[self currentContext] deleteObject:currentObject];
    }
}

// TO DO: Remove deleted objects from memory cache here

- (void)deleteObjectsWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName valueList:(NSArray *)valueList
{
    if (!entityName || !identityPropertyName || valueList.count < 1) {
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

#pragma mark - Queries

- (NSArray *)objectsForEntityWithName:(NSString *)entityName
{
    return [self objectsForEntityWithName:entityName filteredByProperty:nil valueSet:nil];
}

- (NSArray *)objectsForEntityWithName:(NSString *)entityName filteredByProperty:(NSString *)propertyName valueSet:(NSSet *)valueSet
{
    if (!entityName) {
        return nil;
    }
    
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName sortDescriptors:nil];
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

- (NSManagedObject *)performSingleResultFetchOfEntityWithName:(NSString *)entityName byProperty:(NSString *)propertyName value:(id)propertyValue error:(NSError **)error
{
    if (!entityName || !propertyName || !propertyValue) {
        return nil;
    }
    
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName byProperty:propertyName value:propertyValue sortDescriptors:nil];
    if (!fetchRequest) {
        return nil;
    }
    
    return [self performSingleResultFetchRequest:fetchRequest error:error];
}

- (NSArray *)performFetchOfEntityWithName:(NSString *)entityName byProperty:(NSString *)propertyName value:(id)propertyValue sortDescriptors:(NSArray *)sortDescriptors error:(NSError **)error
{
    if (!entityName || !propertyName || !propertyValue) {
        return nil;
    }
    
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName byProperty:propertyName value:propertyValue sortDescriptors:sortDescriptors];
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
    if (!results) {
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
    
    NSArray *results = [[self currentContext] executeFetchRequest:fetchRequest error:error];
    if (!results) {
        NSLog(@"Error for fetch request %@: %@", fetchRequest, *error);
    }
    
    return results;
}

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

- (NSFetchRequest *)fetchRequestForEntityName:(NSString *)entityName byProperty:(NSString *)propertyName value:(id)value sortDescriptors:(NSArray *)sortDescriptors
{
    if (!entityName || !propertyName || !value) {
        return nil;
    }
    
    NSFetchRequest *fetchRequest = [self fetchRequestForEntityName:entityName sortDescriptors:sortDescriptors];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"%K == %@", propertyName, value];
    
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

- (NSDictionary *)updatedEntityKeysForContext:(NSManagedObjectContext *)context
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

- (NSString *)description
{
    return [[super description] stringByAppendingFormat:@"\nUpdated Objects: %lu\nInserted Objects: %lu\nDeleted Objects: %lu", (unsigned long)_updatedObjects.count, (unsigned long)_insertedObjects.count, (unsigned long)_deletedObjects.count];
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