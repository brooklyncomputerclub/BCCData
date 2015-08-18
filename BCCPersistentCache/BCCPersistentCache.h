//
//  BCCPersistentCache.h
//
//  Created by Buzz Andersen on 6/24/11.
//  Copyright 2013 Brooklyn Computer Club. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import "BCCDataStoreController.h"


@class BCCPersistentCacheItem;


extern NSString *BCCPersistentCacheItemUpdatedNotification;
extern NSString *BCCPersistentCacheItemUserInfoItemKey;
extern NSString *BCCPersistentCacheItemUserInfoDataKey;


typedef void (^BCCPersistentCacheBlock)(void);


@interface BCCPersistentCache : BCCDataStoreController <NSCacheDelegate> 

@property (strong, nonatomic, readonly) NSString *fileCachePath;
@property (nonatomic) NSUInteger maximumMemoryCacheSize;
@property (nonatomic) NSUInteger maximumFileCacheSize;
@property (nonatomic, readonly) NSUInteger totalFileCacheSize;
@property (nonatomic) BOOL usesMemoryCache;

// Static Methods
+ (NSString *)metadataModelPath;

// Initialization
- (id)initWithIdentifier:(NSString *)inIdentifier;
- (id)initWithIdentifier:(NSString *)inIdentifier rootDirectory:(NSString *)inRootPath;

// Public Methods
- (void)setCacheData:(NSData *)inData forKey:(NSString *)inKey;
- (void)setCacheData:(NSData *)inData forKey:(NSString *)inKey inBackground:(BOOL)inBackground didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;
- (void)setCacheData:(NSData *)inData forKey:(NSString *)inKey withAttributes:(NSDictionary *)attributes inBackground:(BOOL)inBackground didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;

- (void)addCacheDataFromFileAtPath:(NSString *)inPath forKey:(NSString *)inKey;
- (void)addCacheDataFromFileAtPath:(NSString *)inPath forKey:(NSString *)inKey inBackground:(BOOL)inBackground didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;
- (void)addCacheDataFromFileAtPath:(NSString *)inPath forKey:(NSString *)inKey withAttributes:(NSDictionary *)attributes inBackground:(BOOL)inBackground  didPersistBlock:(BCCPersistentCacheBlock)didPersistBlock;

- (BOOL)hasCacheDataForKey:(NSString *)inKey;
- (NSData *)cacheDataForKey:(NSString *)inKey;
- (NSData *)fileCacheDataForKey:(NSString *)inKey;
- (NSDictionary *)attributesForKey:(NSString *)inKey;

- (void)removeCacheDataForKey:(NSString *)inKey;
- (void)clearMemoryCache;
- (void)clearCache;

@end
