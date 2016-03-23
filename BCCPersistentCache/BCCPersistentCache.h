//
//  BCCPersistentCache.h
//
//  Created by Buzz Andersen on 6/24/11.
//  Copyright 2013 Brooklyn Computer Club. All rights reserved.
//

#import <Foundation/Foundation.h>


@class BCCPersistentCacheItem;


extern NSString *BCCPersistentCacheItemUpdatedNotification;
extern NSString *BCCPersistentCacheItemUserInfoItemKey;
extern NSString *BCCPersistentCacheItemUserInfoDataKey;


typedef void (^BCCPersistentCacheBlock)(void);


@interface BCCPersistentCache : NSObject <NSCacheDelegate>

@property (nonatomic) BOOL usesMemoryCache;
@property (nonatomic) NSUInteger maximumMemoryCacheSize;

@property (nonatomic) NSUInteger maximumFileCacheSize;
@property (nonatomic, readonly) NSUInteger currentFileCacheSize;
@property (strong, nonatomic, readonly) NSString *readOnly;


// Initialization
- (id)initWithIdentifier:(NSString *)identifier;
- (id)initWithIdentifier:(NSString *)identifier rootDirectory:(NSString *)rootPath;

// Public Methods
- (void)setCacheData:(NSData *)data forKey:(NSString *)key;
- (void)setCacheData:(NSData *)data forKey:(NSString *)key inBackground:(BOOL)inBackground didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;
- (void)setCacheData:(NSData *)data forKey:(NSString *)key withAttributes:(NSDictionary *)attributes inBackground:(BOOL)inBackground didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;

- (void)addCacheDataFromFileAtPath:(NSString *)path forKey:(NSString *)key;
- (void)addCacheDataFromFileAtPath:(NSString *)path forKey:(NSString *)key inBackground:(BOOL)inBackground didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;
- (void)addCacheDataFromFileAtPath:(NSString *)path forKey:(NSString *)key withAttributes:(NSDictionary *)attributes inBackground:(BOOL)inBackground didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;

- (BOOL)hasCacheDataForKey:(NSString *)key;
- (NSData *)cacheDataForKey:(NSString *)key;
- (NSData *)fileCacheDataForKey:(NSString *)key;
- (NSDictionary *)attributesForKey:(NSString *)key;

- (void)removeCacheDataForKey:(NSString *)key;
- (void)clearMemoryCache;
- (void)clearCache;

@end
