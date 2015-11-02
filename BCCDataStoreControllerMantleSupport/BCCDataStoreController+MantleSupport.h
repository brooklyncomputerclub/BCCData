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



- (NSArray * _Nullable)createObjectsFromMantleObjectArray:(NSArray <MTLModel *> * _Nonnull)mantleObjectArray usingImportParameters:(BCCDataStoreControllerImportParameters * _Nonnull)importParameters identityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters postCreateBlock:(BCCDataStoreControllerPostCreateBlock _Nullable)postCreateBlock;

- (NSManagedObject * _Nullable)createAndInsertObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject identityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters;

- (NSManagedObject * _Nullable)findOrCreateObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject identityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters;



- (NSArray * _Nullable)mantleObjectsOfClass:(Class _Nonnull)modelClass forIdentityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters groupIdentifier:(NSString * _Nullable)groupIdentifier sortDescriptors:(NSArray * _Nullable)sortDescriptors;

- (NSArray * _Nullable)mantleObjectsOfClass:(Class _Nonnull)modelClass forIdentityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters groupIdentifier:(NSString * _Nullable)groupIdentifier filteredByProperty:(NSString * _Nullable)propertyName valueSet:(NSSet * _Nullable)valueSet sortDescriptors:(NSArray * _Nullable)sortDescriptors;

@end


@protocol BCCDataStoreControllerMantleObjectSerializing <MTLModel>

@required
+ (NSDictionary * _Nonnull)managedObjectKeysByPropertyKey;

@optional
+ (NSValueTransformer * _Nonnull)entityAttributeTransformerForKey:(NSString * _Nonnull)key;

@end