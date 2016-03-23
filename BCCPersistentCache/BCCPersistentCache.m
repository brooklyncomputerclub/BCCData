//
//  BCCPersistentCache.m
//
//  Created by Buzz Andersen on 6/24/11.
//  Copyright 2011 Brooklyn Computer Club. All rights reserved.
//

#import "BCCPersistentCache.h"
#import "NSFileManager+BCCAdditions.h"
#import "NSString+BCCAdditions.h"

#import <sqlite3.h>


@class BCCWorkerQueue;
@class BCCWorkerQueueParameters;

//BCCWorkerQueue

typedef enum {
    BCCWorkerQueueExecutionStyleMainQueueAndWait,
    BCCWorkerQueueExecutionStyleMainQueue,
    BCCWorkerQueueExecutionStyleBackgroundQueueAndWait,
    BCCWorkerQueueExecutionStyleBackgroundQueue
} BCCWorkerQueueExecutionStyle;

typedef void (^BCCWorkerQueueBlock)(BCCWorkerQueue *workerQueue, BCCWorkerQueueParameters *parameters);

@interface BCCWorkerQueueParameters : NSObject

@property (nonatomic) BCCWorkerQueueExecutionStyle workExecutionStyle;
@property (nonatomic) BOOL shouldSave;
@property (nonatomic) NSTimeInterval executionDelay;

@property (copy) BCCWorkerQueueBlock workBlock;
@property (copy) BCCWorkerQueueBlock postSaveBlock;

@end

@interface BCCWorkerQueue : NSObject

@property (copy) BCCWorkerQueueBlock saveBlock;

- (instancetype)initWithIdentifier:(NSString *)identifier;
- (void)performWorkWithParameters:(BCCWorkerQueueParameters *)workParameters;

@end



// Constants
NSString *BCCPersistentCacheFileCacheSubdirectoryName = @"Data";

NSString *BCCPersistentCacheItemUpdatedNotification = @"BCCPersistentCacheItemUpdatedNotification";
NSString *BCCPersistentCacheItemCacheKeyModelKey = @"key";
NSString *BCCPersistentCacheItemAddedTimestampModelKey = @"addedTimestamp";
NSString *BCCPersistentCacheItemFileSizeModelKey = @"fileSize";
NSString *BCCPersistentCacheItemDataModelKey = @"data";

// 2MB      2097152
// 10 MB    10485760
// 20 MB    20971520;

const unsigned long long BCCPersistentCacheDefaultMaximumFileCacheSize = 20971520;


@interface BCCPersistentCacheItem : NSObject

@property (strong, nonatomic) NSString *key;
@property (strong, nonatomic) NSString *filePath;
@property (strong, nonatomic) NSDate *addedTimestamp;
@property (strong, nonatomic) NSDate *updatedTimestamp;
@property (strong, nonatomic) NSDictionary *attributes;
@property (nonatomic) NSUInteger fileSize;

// Public Methods
- (void)initializeForKey:(NSString *)inKey withAttributes:(NSDictionary *)attributes;
- (void)initializeWithData:(NSData *)inData forKey:(NSString *)inKey withAttributes:(NSDictionary *)attributes;
- (void)initializeWithPath:(NSString *)inPath forKey:(NSString *)inKey withAttributes:(NSDictionary *)inAttributes;

@end


@interface BCCPersistentCache ()

@property (strong, nonatomic) NSString *identifier;

@property (strong, nonatomic) NSCache *memoryCache;

@property (strong, nonatomic) NSString *rootDirectory;
@property (strong, nonatomic) NSString *fileCachePath;
@property (nonatomic) BOOL needsCacheTruncation;

@property (nonatomic) sqlite3 *databaseConnection;
@property (nonatomic) sqlite3_stmt *findCacheItemByKeyStatement;

@property (strong, nonatomic) BCCWorkerQueue *workerQueue;

+ (NSString *)defaultRootDirectoryForIdentifier:(NSString *)identifier rootPath:(NSString *)rootPath;

// Cache Items
- (BCCPersistentCacheItem *)cacheItemForKey:(NSString *)key;
- (void)removeCacheItem:(BCCPersistentCacheItem *)inCacheItem;

// Private Methods
- (void)setFileCacheData:(NSData *)data forKey:(NSString *)key withAttributes:(NSDictionary *)attributes didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;
- (NSString *)fileCachePathForKey:(NSString *)key;
- (void)clearFileCache;
- (void)clearCacheItemsToFitMaxFileCacheSize;
- (void)clearCacheItemsOfSize:(unsigned long long)size;
- (void)sendCacheItemUpdatedNotificationForItem:(BCCPersistentCacheItem *)updatedItem data:(NSData *)data;

@end


#pragma mark - BCCPersistentCache

@implementation BCCPersistentCache

#pragma mark - Class Methods

+ (NSString *)defaultRootDirectoryForIdentifier:(NSString *)inIdentifier rootPath:(NSString *)rootPath
{
    NSMutableArray *pathComponents = [[NSMutableArray alloc] init];
    
    // If we're on a Mac, include the app name in the
    // application support path.
#if !TARGET_OS_IPHONE
    [pathComponents addObject:[[NSFileManager defaultManager] BCC_cachePathIncludingAppName]];
#else
    [pathComponents addObject:[[NSFileManager defaultManager] BCC_cachePath]];
#endif
    
    if (rootPath) {
        [pathComponents addObject:rootPath];
    }
    
    [pathComponents addObject:inIdentifier];
        
    NSString *path = [NSString pathWithComponents:pathComponents];
    
    return path;
}

#pragma mark - Initialization

- (id)initWithIdentifier:(NSString *)identifier
{
    if (!(self = [self initWithIdentifier:identifier rootDirectory:nil])) {
        return nil;
    }
    
    return self;
}

- (id)initWithIdentifier:(NSString *)identifier rootDirectory:(NSString *)rootDirectory
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _identifier = identifier;
    
    _rootDirectory = rootDirectory ? rootDirectory : [BCCPersistentCache defaultRootDirectoryForIdentifier:identifier rootPath:nil];
    
    _usesMemoryCache = YES;
    
    _maximumFileCacheSize = BCCPersistentCacheDefaultMaximumFileCacheSize;
    
    _memoryCache = [[NSCache alloc] init];
    _memoryCache.delegate = self;
    
    _databaseConnection = NULL;
    
    [self openDatabaseConnection];
    [self findCacheItemForKey:@"test"];
    
    return self;
}

- (void)dealloc;
{
    int err = sqlite3_finalize(_findCacheItemByKeyStatement);
    err = sqlite3_close(_databaseConnection);
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Accessors

- (void)setRootDirectory:(NSString *)rootDirectory
{
    _rootDirectory = rootDirectory;
    _fileCachePath = [rootDirectory stringByAppendingPathComponent:BCCPersistentCacheFileCacheSubdirectoryName];
}

- (void)setMaximumMemoryCacheSize:(NSUInteger)maximumMemoryCacheSize
{
    self.memoryCache.totalCostLimit = maximumMemoryCacheSize;
}

- (NSUInteger)maximumMemoryCacheSize
{
    return self.memoryCache.totalCostLimit;
}

- (void)setMaximumFileCacheSize:(NSUInteger)maximumFileCacheSize
{
    _maximumFileCacheSize = maximumFileCacheSize;
    self.needsCacheTruncation = YES;
}

- (NSUInteger)totalFileCacheSize;
{
    if (!self.fileCachePath) {
        return 0;
    }
    
    return (NSUInteger)[[NSFileManager defaultManager] BCC_fileSizeAtPath:self.fileCachePath];
}

- (void)setNeedsCacheTruncation:(BOOL)needsCacheTruncation
{
    // If we're not already set as needing cache truncation, we don't need
    // to kick off another truncation job.
    BOOL shouldStartDelayedTrunctation = !self.needsCacheTruncation && needsCacheTruncation;
    
    _needsCacheTruncation = needsCacheTruncation;
    
    if (shouldStartDelayedTrunctation) {
        // This is designed to ensure that truncation jobs run no more than
        // once every 2 seconds, and only if something has actually been
        // added to the cache.

        BCCWorkerQueueBlock truncateCacheBlock = ^(BCCWorkerQueue *workerQueue, BCCWorkerQueueParameters *workParameters) {
            // If we were set to no longer need cache truncation during the
            // delay, cancel the truncation job
            if (!self.needsCacheTruncation) {
                return;
            }
            
            [self clearCacheItemsToFitMaxFileCacheSize];
            
            _needsCacheTruncation = NO;
        };

        [self performBlockOnBackgroundQueue:truncateCacheBlock afterDelay:2.0];
    }
}

- (void)setUsesMemoryCache:(BOOL)usesMemoryCache
{
    _usesMemoryCache = usesMemoryCache;
    
    if (self.memoryCache && !usesMemoryCache) {
        _memoryCache = nil;
    }
}

#pragma mark - NSCacheDelegate

- (void)cache:(NSCache *)cache willEvictObject:(id)obj
{
    NSLog(@"Memory cache evicting object.");
}

#pragma mark - Public Methods

- (void)setCacheData:(NSData *)inData forKey:(NSString *)inKey;
{
    [self setCacheData:inData forKey:(NSString *)inKey inBackground:NO didPersistBlock:NULL];
}

- (void)setCacheData:(NSData *)inData forKey:(NSString *)inKey inBackground:(BOOL)inBackground didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;
{
    [self setCacheData:inData forKey:inKey withAttributes:nil inBackground:inBackground didPersistBlock:didPersistBlock];
}

- (void)setCacheData:(NSData *)inData forKey:(NSString *)inKey withAttributes:(NSDictionary *)attributes inBackground:(BOOL)inBackground didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;
{
    if (!inKey.length || !inData.length) {
        return;
    }
    
    BCCWorkerQueueBlock setDataBlock = ^(BCCWorkerQueue *workerQueue, BCCWorkerQueueParameters *workParameters) {
        // Add the data to the memory cache
        if (self.usesMemoryCache) {
            [self.memoryCache setObject:inData forKey:inKey cost:[inData length]];
        }
        
        [self setFileCacheData:inData forKey:inKey withAttributes:attributes didPersistBlock:didPersistBlock];
    };

    if (inBackground) {
        [self performBlockOnBackgroundQueue:setDataBlock];
    } else {
        [self performBlockOnMainQueueAndWait:setDataBlock];
    }
}

- (void)setFileCacheData:(NSData *)inData forKey:(NSString *)inKey withAttributes:(NSDictionary *)attributes didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock
{
    if (!inKey.length || !inData.length) {
        return;
    }
    
    // Add the data to the file cache (should overwrite)
    NSString *filePath = [self fileCachePathForKey:inKey];
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.fileCachePath]) {
        [[NSFileManager defaultManager] BCC_recursivelyCreatePath:self.fileCachePath];
    }
    
    [inData writeToFile:filePath atomically:NO];
    
    // Create a cache item or update the existing one
    BCCPersistentCacheItem *item = [self findOrCreateCacheItemForKey:inKey];
    [item initializeWithData:inData forKey:inKey withAttributes:attributes];
    
    if (didPersistBlock) {
        didPersistBlock();
    }
    
    self.needsCacheTruncation = YES;
}

- (void)addCacheDataFromFileAtPath:(NSString *)path forKey:(NSString *)key
{
    [self addCacheDataFromFileAtPath:path forKey:key inBackground:NO didPersistBlock:NULL];
}

- (void)addCacheDataFromFileAtPath:(NSString *)inPath forKey:(NSString *)inKey inBackground:(BOOL)inBackground didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock
{
    [self addCacheDataFromFileAtPath:inPath forKey:inKey withAttributes:nil inBackground:inBackground didPersistBlock:didPersistBlock];
}

- (void)addCacheDataFromFileAtPath:(NSString *)path forKey:(NSString *)key withAttributes:(NSDictionary *)attributes inBackground:(BOOL)inBackground didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock
{
    if (!key || !path) {
        return;
    }
    
    BCCWorkerQueueBlock setDataBlock = ^(BCCWorkerQueue *workerQueue, BCCWorkerQueueParameters *workParameters) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return;
        }
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.fileCachePath]) {
            [[NSFileManager defaultManager] BCC_recursivelyCreatePath:self.fileCachePath];
        }

        NSString *filePath = [self fileCachePathForKey:key];
        NSError *moveError;
        BOOL success = [[NSFileManager defaultManager] moveItemAtPath:path toPath:filePath error:&moveError];
        if (!success) {
            NSLog(@"Unable to add file at path %@ to cache due to error: %@", path, moveError);
            return;
        }
        
        // Create a cache item or update the existing one
        BCCPersistentCacheItem *item = [self findOrCreateCacheItemForKey:key];
        [item initializeWithPath:path forKey:key withAttributes:attributes];
        
        if (didPersistBlock) {
            dispatch_async(dispatch_get_main_queue(), didPersistBlock);
        }
        
        self.needsCacheTruncation = YES;
    };
    
    if (inBackground) {
        [self performBlockOnBackgroundQueue:setDataBlock];
    } else {
        [self performBlockOnMainQueueAndWait:setDataBlock];
    }
}

- (void)removeCacheDataForKey:(NSString *)key
{
    if (!key.length) {
        return;
    }
    
    [self performBlockOnMainQueue:^(BCCWorkerQueue *workerQueue, BCCWorkerQueueParameters *workParameters) {
        BCCPersistentCacheItem *cacheItem = [self cacheItemForKey:key];
        if (cacheItem) {
            [self removeCacheItem:cacheItem];
        }
    }];
}

- (void)removeCacheItem:(BCCPersistentCacheItem *)cacheItem
{
    if (!cacheItem) {
        return;
    }
    
    NSString *key = cacheItem.key;
    
    // Remove the data from the memory cache
    if (self.usesMemoryCache) {
        [self.memoryCache removeObjectForKey:key];
    }
    
    // Remove the data from the file cache
    NSString *filePath = [self fileCachePathForKey:key];
    [[NSFileManager defaultManager] removeItemAtPath:filePath error:NULL];
        
    // Delete the cache item
    [self deleteCacheItemForKey:key];
}

- (NSDictionary *)attributesForKey:(NSString *)key
{
    __block BCCPersistentCacheItem *item = nil;
    
    [self performBlockOnBackgroundQueueAndWait:^(BCCWorkerQueue *workerQueue, BCCWorkerQueueParameters *workParameters) {
        item = [self cacheItemForKey:key];
    }];
    return item.attributes;
}

- (BCCPersistentCacheItem *)cacheItemForKey:(NSString *)key
{
    if (!key) {
        return nil;
    }
    
    BCCPersistentCacheItem *item = [self findCacheItemForKey:key];
    
    return item;
}

- (NSData *)cacheDataForKey:(NSString *)key
{
    if (!key) {
        return nil;
    }
    
    if (self.usesMemoryCache) {
        NSData *memoryData = [self.memoryCache objectForKey:key];
        if (memoryData) {
            return memoryData;
        }
    }
    
    NSData *fileData = [self fileCacheDataForKey:key];
    if (fileData.length && self.usesMemoryCache) {
        [self.memoryCache setObject:fileData forKey:key cost:[fileData length]];
    }
   
    return fileData;
}

- (NSData *)fileCacheDataForKey:(NSString *)key
{    
    NSString *cachePath = [self fileCachePathForKey:key];
    if (!cachePath) {
        return nil;
    }
    
    return [NSData dataWithContentsOfFile:cachePath];
}

- (void)clearCache;
{
    [self clearMemoryCache];

    [self clearCacheItemDatabase];
    [self clearFileCache];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.fileCachePath]) {
        [[NSFileManager defaultManager] BCC_recursivelyCreatePath:self.fileCachePath];
    }
}

- (void)clearMemoryCache
{
    [self.memoryCache removeAllObjects];
}

- (BOOL)hasCacheDataForKey:(NSString *)key
{
    NSString *filePath = [self fileCachePathForKey:key];
    return [[NSFileManager defaultManager] fileExistsAtPath:filePath];
}

#pragma mark - Queue Management

- (void)performBlockOnMainQueue:(BCCWorkerQueueBlock)block
{
    BCCWorkerQueueParameters *workParameters = [[BCCWorkerQueueParameters alloc] init];
    workParameters.workExecutionStyle = BCCWorkerQueueExecutionStyleMainQueue;
    workParameters.workBlock = block;
    
    [self.workerQueue performWorkWithParameters:workParameters];
}

- (void)performBlockOnMainQueueAndWait:(BCCWorkerQueueBlock)block
{
    BCCWorkerQueueParameters *workParameters = [[BCCWorkerQueueParameters alloc] init];
    workParameters.workExecutionStyle = BCCWorkerQueueExecutionStyleMainQueueAndWait;
    workParameters.workBlock = block;
    
    [self.workerQueue performWorkWithParameters:workParameters];
}

- (void)performBlockOnMainQueue:(BCCWorkerQueueBlock)block afterDelay:(NSTimeInterval)delay
{
    BCCWorkerQueueParameters *workParameters = [[BCCWorkerQueueParameters alloc] init];
    workParameters.workExecutionStyle = BCCWorkerQueueExecutionStyleMainQueue;
    workParameters.executionDelay = delay;
    workParameters.workBlock = block;
    
    [self.workerQueue performWorkWithParameters:workParameters];
}

- (void)performBlockOnBackgroundQueue:(BCCWorkerQueueBlock)block
{
    BCCWorkerQueueParameters *workParameters = [[BCCWorkerQueueParameters alloc] init];
    workParameters.workExecutionStyle = BCCWorkerQueueExecutionStyleBackgroundQueue;
    workParameters.workBlock = block;
    
    [self.workerQueue performWorkWithParameters:workParameters];
}

- (void)performBlockOnBackgroundQueueAndWait:(BCCWorkerQueueBlock)block
{
    BCCWorkerQueueParameters *workParameters = [[BCCWorkerQueueParameters alloc] init];
    workParameters.workExecutionStyle = BCCWorkerQueueExecutionStyleBackgroundQueueAndWait;
    workParameters.workBlock = block;
    
    [self.workerQueue performWorkWithParameters:workParameters];
}

- (void)performBlockOnBackgroundQueue:(BCCWorkerQueueBlock)block afterDelay:(NSTimeInterval)delay
{
    BCCWorkerQueueParameters *workParameters = [[BCCWorkerQueueParameters alloc] init];
    workParameters.workExecutionStyle = BCCWorkerQueueExecutionStyleBackgroundQueue;
    workParameters.executionDelay = delay;
    workParameters.workBlock = block;
    
    [self.workerQueue performWorkWithParameters:workParameters];
}

#pragma mark - Private Methods

- (NSString *)fileCachePathForKey:(NSString *)key
{
    if (!key || !self.fileCachePath) {
        return nil;
    }
    
    return [self.fileCachePath stringByAppendingPathComponent:[key BCC_MD5String]];
}

- (void)clearFileCache
{
    [[NSFileManager defaultManager] removeItemAtPath:self.fileCachePath error:NULL];
}

- (void)clearCacheItemsToFitMaxFileCacheSize
{
    NSUInteger cacheSize = self.totalFileCacheSize;
    if (cacheSize <= self.maximumFileCacheSize) {
        return;
    }
    
    NSUInteger spaceToClear = cacheSize - self.maximumFileCacheSize;
    [self clearCacheItemsOfSize:spaceToClear];
}

- (void)clearCacheItemsOfSize:(unsigned long long)size
{
    NSLog(@"Clearing Persistent Cache");
    
    if (!size) {
        return;
    } else if (size >= self.totalFileCacheSize) {
        [self clearCache];
        return;
    }
    
    [self performBlockOnBackgroundQueue:^(BCCWorkerQueue *workerQueue, BCCWorkerQueueParameters *workParameters) {
        NSArray *cacheItems = [self allCacheItems];
        if (cacheItems.count < 1) {
            return;
        }
        
        unsigned long long totalCleared = 0;
        
        for (BCCPersistentCacheItem *currentItem in cacheItems) {
            unsigned long long itemSize = currentItem.fileSize;
            
            [self removeCacheItem:currentItem];
            
            totalCleared += itemSize;
            
            if (totalCleared >= size) {
                break;
            }
        }
    }];
}

- (void)sendCacheItemUpdatedNotificationForItem:(BCCPersistentCacheItem *)updatedItem data:(NSData *)inData;
{
    /*dispatch_async(self.workerQueue, ^{
        NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:updatedItem, BCCPersistentCacheItemUserInfoItemKey, inData, BCCPersistentCacheItemUserInfoDataKey, nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:BCCPersistentCacheItemUpdatedNotification
                                                            object:updatedItem.key
                                                          userInfo:userInfo];     
});*/
}

#pragma mark - Database Methods

- (void)openDatabaseConnection
{
    NSString *rootDirectory = self.rootDirectory;
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:rootDirectory]) {
        [[NSFileManager defaultManager] BCC_recursivelyCreatePath:rootDirectory];
    }
    
    NSString *databasePath = [[rootDirectory stringByAppendingPathComponent:@"CacheItems"] stringByAppendingPathExtension:@"sqlite"];
    int err = sqlite3_open([databasePath UTF8String], &(_databaseConnection));
    if (err != SQLITE_OK) {
        NSLog(@"%s", sqlite3_errstr(err));
        return;
    }
    
    NSString *createTableSQL = @"CREATE TABLE IF NOT EXISTS cache_items(id INTEGER PRIMARY KEY ASC, key TEXT NOT NULL, data_file_path TEXT, file_size INTEGER, date_added INTEGER, date_modified INTEGER)";
    
    char *errString;
    sqlite3_exec(_databaseConnection, [createTableSQL UTF8String], NULL, NULL, &errString);
    if (errString) {
        NSLog(@"Cache Item Database Error: %s", errString);
    }
}

- (NSArray *)allCacheItems
{
    return nil;
}

- (BCCPersistentCacheItem *)findOrCreateCacheItemForKey:(NSString *)key
{
    return nil;
}

- (BCCPersistentCacheItem *)findCacheItemForKey:(NSString *)key
{
    if (!key) {
        return nil;
    }
    
    if (!_findCacheItemByKeyStatement) {
        NSString *findSQL = @"SELECT id, key, data_file_path, file_size, date_added, date_modified FROM cache_items WHERE key == ?";
        int err = sqlite3_prepare_v2(_databaseConnection, [findSQL UTF8String], -1, &(_findCacheItemByKeyStatement), NULL);
        if (err != SQLITE_OK) {
            NSLog(@"Cache Item Database Error: %s", sqlite3_errstr(err));
            return nil;
        }
    }
    
    int err = sqlite3_bind_text(_findCacheItemByKeyStatement, 1, [key UTF8String], -1, SQLITE_TRANSIENT);
    if (err != SQLITE_OK) {
        NSLog(@"%s", sqlite3_errstr(err));
        return nil;
    }
    
    BCCPersistentCacheItem *item = nil;

    err = sqlite3_step(_findCacheItemByKeyStatement);
    if (err != SQLITE_ROW) {
        NSLog(@"%s", sqlite3_errstr(err));
        goto cleanup;
    }
    
    item = [[BCCPersistentCacheItem alloc] init];
    
    const unsigned char *keyChars = sqlite3_column_text(_findCacheItemByKeyStatement, 1);
    if (keyChars != NULL) {
        item.key = [[NSString alloc] initWithBytes:keyChars length:sizeof(keyChars) encoding:NSUTF8StringEncoding];
    }
    
    const unsigned char *filePathChars = sqlite3_column_text(_findCacheItemByKeyStatement, 2);
    if (filePathChars != NULL) {
        item.filePath = [[NSString alloc] initWithBytes:keyChars length:sizeof(filePathChars) encoding:NSUTF8StringEncoding];
    }
    
cleanup:
    err = sqlite3_reset(_findCacheItemByKeyStatement);
    return item;
}

- (void)deleteCacheItemForKey:(NSString *)key
{
    
}

- (void)clearCacheItemDatabase
{
    
}

@end


#pragma mark - Cache Item Model

@implementation BCCPersistentCacheItem

#pragma mark Public Methods

- (void)initializeForKey:(NSString *)inKey withAttributes:(NSDictionary *)attributes;
{
    if (!inKey.length) {
        return;
    }
    
    self.key = inKey;
    self.filePath = [inKey BCC_MD5String];
    
    if (!self.addedTimestamp) {
        self.addedTimestamp = [NSDate date];
    }
    
    self.updatedTimestamp = [NSDate date];
    self.attributes = attributes;
}

- (void)initializeWithData:(NSData *)inData forKey:(NSString *)inKey withAttributes:(NSDictionary *)inAttributes;
{
    if (!inData.length || !inKey.length) {
        return;
    }
    
    [self initializeForKey:inKey withAttributes:inAttributes];
    self.fileSize = inData.length;
}

- (void)initializeWithPath:(NSString *)inPath forKey:(NSString *)inKey withAttributes:(NSDictionary *)inAttributes;
{
    if (!inPath.length || !inKey.length) {
        return;
    }
    
    [self initializeForKey:inKey withAttributes:inAttributes];
    self.fileSize = [[NSFileManager defaultManager] BCC_fileSizeAtPath:inPath];
}

@end


#pragma mark - BCCWorkerQueue

@implementation BCCWorkerQueueParameters

@end


@interface BCCWorkerQueue ()

@property (strong, nonatomic) dispatch_queue_t backgroundQueue;

@end

@implementation BCCWorkerQueue

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _backgroundQueue = dispatch_queue_create([identifier UTF8String], DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(_backgroundQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    
    return self;
}

- (void)performWorkWithParameters:(BCCWorkerQueueParameters *)workParameters {
    BCCWorkerQueueBlock workBlock = workParameters.workBlock;
    BCCWorkerQueueBlock postSaveBlock = workParameters.postSaveBlock;
    
    if (!workBlock) {
        return;
    }
    
    BOOL save = workParameters.shouldSave;
    BOOL delay = workParameters.executionDelay;
    BOOL wait = NO;
    
    dispatch_queue_t executionQueue = dispatch_get_main_queue();
    
    switch (workParameters.workExecutionStyle) {
        case BCCWorkerQueueExecutionStyleMainQueueAndWait:
            wait = YES;
            break;
        case BCCWorkerQueueExecutionStyleBackgroundQueue:
            executionQueue = self.backgroundQueue;
            break;
        case BCCWorkerQueueExecutionStyleBackgroundQueueAndWait:
            executionQueue = self.backgroundQueue;
            wait = YES;
            break;
        default:
            break;
    }
    
    void (^metaBlock)(void) = ^(void) {
        workBlock(self, workParameters);
        
        if (save && self.saveBlock) {
            self.saveBlock(self, workParameters);
            
            if (postSaveBlock) {
                postSaveBlock(self, workParameters);
            }
        }
    };
    
    void (^executionBlock)(void) = ^(void) {
        if (wait) {
            dispatch_sync(executionQueue, metaBlock);
        } else {
            metaBlock();
        }
    };
    
    if (delay) {
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC);
        dispatch_after(popTime, executionQueue, executionBlock);
    } else {
        executionBlock();
    }
}

@end
