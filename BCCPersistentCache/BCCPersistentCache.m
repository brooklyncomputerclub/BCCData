//
//  BCCPersistentCache.m
//
//  Created by Buzz Andersen on 6/24/11.
//  Copyright 2011 Brooklyn Computer Club. All rights reserved.
//

#import "BCCPersistentCache.h"
#import "NSFileManager+BCCAdditions.h"
#import "NSManagedObject+BCCAdditions.h"
#import "NSString+BCCAdditions.h"


// Constants
NSString *BCCPersistentCacheMetadataModelName = @"BCCPersistentCache";

NSString *BCCPersistentCacheFileCacheSubdirectoryName = @"Data";

NSString *BCCPersistentCacheItemEntityName = @"PersistentCacheItem";
NSString *BCCPersistentCacheItemCacheKeyModelKey = @"key";
NSString *BCCPersistentCacheItemAddedTimestampModelKey = @"addedTimestamp";
NSString *BCCPersistentCacheItemFileSizeModelKey = @"fileSize";
NSString *BCCPersistentCacheItemDataModelKey = @"data";

NSString *BCCPersistentCacheItemUpdatedNotification = @"BCCPersistentCacheItemUpdatedNotification";
NSString *BCCPersistentCacheItemUserInfoItemKey = @"item";
NSString *BCCPersistentCacheItemUserInfoDataKey = @"data";

const unsigned long long STPersistentCacheDefaultMaximumFileCacheSize = 20971520;

// 2MB      2097152
// 10 MB    10485760
// 20 MB    20971520;


@interface BCCPersistentCacheItem : NSManagedObject

@property (strong, nonatomic) NSString *key;
@property (strong, nonatomic) NSString *fileName;
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

@property (strong, nonatomic) NSString *cacheName;
@property (strong, nonatomic) NSCache *memoryCache;
@property (strong, nonatomic) NSString *fileCachePath;
@property (nonatomic) BOOL needsCacheTruncation;

+ (NSString *)defaultRootDirectoryForIdentifier:(NSString *)inIdentifier rootPath:(NSString *)rootPath;

// Cache Items
- (BCCPersistentCacheItem *)cacheItemForKey:(NSString *)inKey;
- (void)removeCacheItem:(BCCPersistentCacheItem *)inCacheItem;

// Private Methods
- (void)setFileCacheData:(NSData *)inData forKey:(NSString *)inKey withAttributes:(NSDictionary *)attributes didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;
- (void)_updateFileCachePath;
- (NSString *)_fileCachePathForKey:(NSString *)inKey;
- (NSString *)_fileCachePathForName:(NSString *)inFileName;
- (void)_clearFileCache;
- (void)_clearCacheItemsToFitMaxFileCacheSize;
- (void)_clearCacheItemsOfSize:(unsigned long long)inSize;
- (void)_sendCacheItemUpdatedNotificationForItem:(BCCPersistentCacheItem *)updatedItem data:(NSData *)inData;

// Private Core Data Methods
- (BCCPersistentCacheItem *)_findOrCreateCacheItemForKey:(NSString *)inKey;

@end


@implementation BCCPersistentCache

#pragma mark Class Methods

+ (NSString *)metadataModelPath
{
    return [[NSBundle mainBundle] pathForResource:BCCPersistentCacheMetadataModelName ofType:@"momd"];
}

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

#pragma mark Initialization

- (id)initWithIdentifier:(NSString *)inIdentifier;
{
    if (!(self = [self initWithIdentifier:inIdentifier rootDirectory:nil])) {
        return nil;
    }
    
    return self;
}

- (id)initWithIdentifier:(NSString *)inIdentifier rootDirectory:(NSString *)inRootPath;
{
    if (!(self = [super initWithIdentifier:inIdentifier modelPath:[BCCPersistentCache metadataModelPath] rootDirectory:[BCCPersistentCache defaultRootDirectoryForIdentifier:inIdentifier rootPath:inRootPath]])) {
        return nil;
    }
    
    [self _updateFileCachePath];
    
    _usesMemoryCache = YES;
    
    _maximumFileCacheSize = STPersistentCacheDefaultMaximumFileCacheSize;
    
    _memoryCache = [[NSCache alloc] init];
    _memoryCache.delegate = self;
    
    return self;
}

- (void)dealloc;
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark Accessors

- (void)setMaximumMemoryCacheSize:(NSUInteger)maximumMemoryCacheSize;
{
    self.memoryCache.totalCostLimit = maximumMemoryCacheSize;
}

- (NSUInteger)maximumMemoryCacheSize;
{
    return self.memoryCache.totalCostLimit;
}

- (void)setMaximumFileCacheSize:(NSUInteger)maximumFileCacheSize;
{
    _maximumFileCacheSize = maximumFileCacheSize;
    self.needsCacheTruncation = YES;
}

- (NSUInteger)totalFileCacheSize;
{
    if (!self.fileCachePath.length) {
        return 0;
    }
    
    return (NSUInteger)[[NSFileManager defaultManager] BCC_fileSizeAtPath:self.fileCachePath];
}

- (void)setNeedsCacheTruncation:(BOOL)inNeedsCacheTruncation;
{
    // If we're not already set as needing cache truncation, we don't need
    // to kick off another truncation job.
    BOOL shouldStartDelayedTrunctation = !self.needsCacheTruncation && inNeedsCacheTruncation;
    
    _needsCacheTruncation = inNeedsCacheTruncation;
    
    if (shouldStartDelayedTrunctation) {
        // This is designed to ensure that truncation jobs run no more than
        // once every 2 seconds, and only if something has actually been
        // added to the cache.

        BCCDataStoreControllerWorkBlock truncateCacheBlock = ^(BCCDataStoreController *dataStoreController, NSManagedObjectContext *context, BCCDataStoreControllerWorkParameters *workParameters) {
            // If we were set to no longer need cache truncation during the
            // delay, cancel the truncation job
            if (!self.needsCacheTruncation) {
                return;
            }
            
            [self _clearCacheItemsToFitMaxFileCacheSize];
            
            _needsCacheTruncation = NO;
        };

        [self performBlockOnBackgroundMOC:truncateCacheBlock afterDelay:2.0];
    }
}

- (void)setUsesMemoryCache:(BOOL)usesMemoryCache
{
    _usesMemoryCache = usesMemoryCache;
    
    if (self.memoryCache && !usesMemoryCache) {
        _memoryCache = nil;
    }
}

#pragma mark NSCacheDelegate

- (void)cache:(NSCache *)cache willEvictObject:(id)obj;
{
    //NSLog(@"Memory cache evicting object.");
}

#pragma mark Public Methods

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
    
    BCCDataStoreControllerWorkBlock setDataBlock = ^(BCCDataStoreController *dataStoreController, NSManagedObjectContext *context, BCCDataStoreControllerWorkParameters *workParameters) {
        // Add the data to the memory cache
        if (self.usesMemoryCache) {
            [self.memoryCache setObject:inData forKey:inKey cost:[inData length]];
        }
        
        [self setFileCacheData:inData forKey:inKey withAttributes:attributes didPersistBlock:didPersistBlock];
    };

    if (inBackground) {
        [self performBlockOnBackgroundMOC:setDataBlock];
    } else {
        [self performBlockOnMainMOCAndWait:setDataBlock];
    }
}

- (void)setFileCacheData:(NSData *)inData forKey:(NSString *)inKey withAttributes:(NSDictionary *)attributes didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock
{
    if (!inKey.length || !inData.length) {
        return;
    }
    
    // Add the data to the file cache (should overwrite)
    NSString *filePath = [self _fileCachePathForKey:inKey];
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.fileCachePath]) {
        [[NSFileManager defaultManager] BCC_recursivelyCreatePath:self.fileCachePath];
    }
    
    [inData writeToFile:filePath atomically:NO];
    
    // Create a cache item or update the existing one
    BCCPersistentCacheItem *item = [self _findOrCreateCacheItemForKey:inKey];
    [item initializeWithData:inData forKey:inKey withAttributes:attributes];
    
    if (didPersistBlock) {
        didPersistBlock();
    }
    
    self.needsCacheTruncation = YES;
}

- (void)addCacheDataFromFileAtPath:(NSString *)inPath forKey:(NSString *)inKey;
{
    [self addCacheDataFromFileAtPath:inPath forKey:inKey inBackground:NO didPersistBlock:NULL];
}

- (void)addCacheDataFromFileAtPath:(NSString *)inPath forKey:(NSString *)inKey inBackground:(BOOL)inBackground didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;
{
    [self addCacheDataFromFileAtPath:inPath forKey:inKey withAttributes:nil inBackground:inBackground didPersistBlock:didPersistBlock];
}

- (void)addCacheDataFromFileAtPath:(NSString *)inPath forKey:(NSString *)inKey withAttributes:(NSDictionary *)attributes inBackground:(BOOL)inBackground  didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;
{
    if (!inKey.length || !inPath.length) {
        return;
    }
    
    BCCDataStoreControllerWorkBlock setDataBlock = ^(BCCDataStoreController *dataStoreController, NSManagedObjectContext *context, BCCDataStoreControllerWorkParameters *workParameters) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:inPath]) {
            return;
        }
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.fileCachePath]) {
            [[NSFileManager defaultManager] BCC_recursivelyCreatePath:self.fileCachePath];
        }

        NSString *filePath = [self _fileCachePathForKey:inKey];
        NSError *moveError;
        BOOL success = [[NSFileManager defaultManager] moveItemAtPath:inPath toPath:filePath error:&moveError];
        if (!success) {
            NSLog(@"Unable to add file at path %@ to cache due to error: %@", inPath, moveError);
            return;
        }
        
        // Create a cache item or update the existing one
        BCCPersistentCacheItem *item = [self _findOrCreateCacheItemForKey:inKey];
        [item initializeWithPath:inPath forKey:inKey withAttributes:nil];
        
        [self saveCurrentMOC];
        
        if (didPersistBlock) {
            dispatch_async(dispatch_get_main_queue(), didPersistBlock);
        }
        
        self.needsCacheTruncation = YES;
    };
    
    if (inBackground) {
        [self performBlockOnBackgroundMOC:setDataBlock];
    } else {
        [self performBlockOnMainMOCAndWait:setDataBlock];
    }
}

- (void)removeCacheDataForKey:(NSString *)inKey;
{
    if (!inKey.length) {
        return;
    }
    
    [self performBlockOnMainMOC:^(BCCDataStoreController *dataStoreController, NSManagedObjectContext *context, BCCDataStoreControllerWorkParameters *workParameters) {
        BCCPersistentCacheItem *cacheItem = [self cacheItemForKey:inKey];
        if (cacheItem) {
            [self removeCacheItem:cacheItem];
        }
    }];
}

- (void)removeCacheItem:(BCCPersistentCacheItem *)inCacheItem;
{
    if (!inCacheItem) {
        return;
    }
    
    NSString *key = inCacheItem.key;
    
    // Remove the data from the memory cache
    if (self.usesMemoryCache) {
        [self.memoryCache removeObjectForKey:key];
    }
    
    // Remove the data from the file cache
    NSString *filePath = [self _fileCachePathForKey:key];
    [[NSFileManager defaultManager] removeItemAtPath:filePath error:NULL];
        
    // Delete the cache item
    [[self currentMOC] deleteObject:inCacheItem];
}

- (NSDictionary *)attributesForKey:(NSString *)inKey;
{
    __block BCCPersistentCacheItem *item = nil;
    /*[self performBlockOnBackgroundMOC:^(BCCDataStoreController *dataStoreController, NSManagedObjectContext *managedObjectContext) {
        item = [self cacheItemForKey:inKey];
        NSLog(@"Found ITEM: %@", item);
    }];
     
    return nil;*/
    
    [self performBlockOnBackgroundMOCAndWait:^(BCCDataStoreController *dataStoreController, NSManagedObjectContext *managedObjectContext, BCCDataStoreControllerWorkParameters *workParameters) {
        item = [self cacheItemForKey:inKey];
    }];
    return item.attributes;
}

- (BCCPersistentCacheItem *)cacheItemForKey:(NSString *)inKey;
{
    if (!inKey.length) {
        return nil;
    }
    
    BCCPersistentCacheItem *item = (BCCPersistentCacheItem *)[self performSingleResultFetchOfEntityWithName:BCCPersistentCacheItemEntityName usingPropertyList:@[BCCPersistentCacheItemCacheKeyModelKey] valueList:@[inKey] error:NULL];
    
    return item;
}

- (NSData *)cacheDataForKey:(NSString *)inKey;
{
    if (!inKey.length) {
        return nil;
    }
    
    if (self.usesMemoryCache) {
        NSData *memoryData = [self.memoryCache objectForKey:inKey];
        if (memoryData) {
            return memoryData;
        }
    }
    
    NSData *fileData = [self fileCacheDataForKey:inKey];
    if (fileData.length && self.usesMemoryCache) {
        [self.memoryCache setObject:fileData forKey:inKey cost:[fileData length]];
    }
   
    return fileData;
}

- (NSData *)fileCacheDataForKey:(NSString *)inKey;
{    
    /*STPersistentCacheItem *cacheItem = [self cacheItemForKey:inKey];
    NSString *cachePath = [self _fileCachePathForName:cacheItem.fileName];
    if (!cachePath) {
        return nil;
    }
    
    return [NSData dataWithContentsOfFile:cachePath];*/
    
    NSString *cachePath = [self _fileCachePathForKey:inKey];
    if (!cachePath) {
        return nil;
    }
    
    return [NSData dataWithContentsOfFile:cachePath];
}

- (void)clearCache;
{
    [self clearMemoryCache];

    [self deletePersistentStore];
    [self _clearFileCache];    
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.fileCachePath]) {
        [[NSFileManager defaultManager] BCC_recursivelyCreatePath:self.fileCachePath];
    }
}

- (void)clearMemoryCache
{
    [self.memoryCache removeAllObjects];
}

- (BOOL)hasCacheDataForKey:(NSString *)inKey
{
    NSString *filePath = [self _fileCachePathForKey:inKey];
    return [[NSFileManager defaultManager] fileExistsAtPath:filePath];
}

#pragma mark Private Methods

- (void)_updateFileCachePath;
{
    self.fileCachePath = [self.rootDirectory stringByAppendingPathComponent:BCCPersistentCacheFileCacheSubdirectoryName];
}

- (NSString *)_fileCachePathForName:(NSString *)inFileName;
{
    if (!inFileName.length || !self.fileCachePath.length) {
        return nil;
    }
    
    return [self.fileCachePath stringByAppendingPathComponent:inFileName];
}

- (NSString *)_fileCachePathForKey:(NSString *)inKey;
{
    if (!inKey.length || !self.fileCachePath.length) {
        return nil;
    }
    
    return [self.fileCachePath stringByAppendingPathComponent:[inKey BCC_MD5String]];
}

- (void)_clearFileCache;
{
    [[NSFileManager defaultManager] removeItemAtPath:self.fileCachePath error:NULL];
}

- (void)_clearCacheItemsToFitMaxFileCacheSize;
{
    NSUInteger cacheSize = self.totalFileCacheSize;
    if (cacheSize <= self.maximumFileCacheSize) {
        return;
    }
    
    NSUInteger spaceToClear = cacheSize - self.maximumFileCacheSize;
    [self _clearCacheItemsOfSize:spaceToClear];
}

- (void)_clearCacheItemsOfSize:(unsigned long long)inSize;
{
    NSLog(@"Clearing Persistent Cache");
    
    if (!inSize) {
        return;
    } else if (inSize >= self.totalFileCacheSize) {
        [self clearCache];
        return;
    }
    
    [self performBlockOnBackgroundMOC:^(BCCDataStoreController *dataStoreController, NSManagedObjectContext *context, BCCDataStoreControllerWorkParameters *workParameters) {
        NSFetchRequest *cacheItemFetchRequest = [self fetchRequestForEntityName:BCCPersistentCacheItemEntityName sortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:BCCPersistentCacheItemAddedTimestampModelKey ascending:NO]]];
        NSError *fetchError = nil;
        NSArray *cacheItems = [self performFetchRequest:cacheItemFetchRequest error:&fetchError];
        if (fetchError || cacheItems.count < 1) {
            return;
        }
        
        unsigned long long totalCleared = 0;
        
        for (BCCPersistentCacheItem *currentItem in cacheItems) {
            unsigned long long itemSize = currentItem.fileSize;
            
            [self removeCacheItem:currentItem];
            
            totalCleared += itemSize;
            
            if (totalCleared >= inSize) {
                break;
            }
        }
    }];
}

- (void)_sendCacheItemUpdatedNotificationForItem:(BCCPersistentCacheItem *)updatedItem data:(NSData *)inData;
{
    //dispatch_async(self.workerQueue, ^{   
        NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:updatedItem, BCCPersistentCacheItemUserInfoItemKey, inData, BCCPersistentCacheItemUserInfoDataKey, nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:BCCPersistentCacheItemUpdatedNotification
                                                            object:updatedItem.key
                                                          userInfo:userInfo];     
    //});
}

#pragma mark Private Core Data Methods

- (BCCPersistentCacheItem *)_findOrCreateCacheItemForKey:(NSString *)inKey;
{
    BCCDataStoreControllerIdentityParameters *identityParameters = [BCCDataStoreControllerIdentityParameters identityParametersWithEntityName:BCCPersistentCacheItemEntityName identityPropertyName:BCCPersistentCacheItemCacheKeyModelKey];
    BCCPersistentCacheItem *item = (BCCPersistentCacheItem *)[self findOrCreateObjectWithIdentityParameters:identityParameters identityValue:inKey groupIdentifier:nil];
    
    return item;
}

@end


@implementation BCCPersistentCacheItem

@dynamic key;
@dynamic fileSize;
@dynamic addedTimestamp;
@dynamic updatedTimestamp;
@dynamic attributes;
@dynamic fileName;

#pragma mark Public Methods

- (void)initializeForKey:(NSString *)inKey withAttributes:(NSDictionary *)attributes;
{
    if (!inKey.length) {
        return;
    }
    
    self.key = inKey;
    self.fileName = [inKey BCC_MD5String];
    
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

#pragma mark Accessors

- (void)setFileSize:(NSUInteger)inFileSize;
{
    [self BCC_setUnsignedInteger:inFileSize forKey:BCCPersistentCacheItemFileSizeModelKey];
}

- (NSUInteger)fileSize;
{
    return [self BCC_unsignedIntegerForKey:BCCPersistentCacheItemFileSizeModelKey];
}

@end

