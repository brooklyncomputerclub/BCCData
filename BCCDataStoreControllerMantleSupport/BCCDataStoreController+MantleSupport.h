//
//  BCCDataStoreController+MantleSupport.h
//  Toilets
//
//  Created by Laurence Andersen on 10/28/15.
//  Copyright © 2015 Brooklyn Computer Club. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Mantle/Mantle.h>

@protocol BCCDataStoreControllerMantleObjectSerializing;


@interface BCCDataStoreController (MantleSupport)

// Mantle -> Core Data

- (NSArray * _Nullable)createObjectsFromMantleObjectArray:(NSArray <MTLModel *> * _Nonnull)mantleObjectArray usingImportParameters:(BCCDataStoreControllerImportParameters * _Nonnull)importParameters identityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters postCreateBlock:(BCCDataStoreControllerPostCreateBlock _Nullable)postCreateBlock;

- (NSManagedObject * _Nullable)createAndInsertObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject identityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters;

- (NSManagedObject * _Nullable)findOrCreateObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject identityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters;

@end


@protocol BCCDataStoreControllerMantleObjectSerializing <MTLModel>

@required
+ (NSDictionary * _Nonnull)managedObjectKeysByPropertyKey;

@optional
+ (NSValueTransformer * _Nonnull)entityAttributeTransformerForKey:(NSString * _Nonnull)key;

@end