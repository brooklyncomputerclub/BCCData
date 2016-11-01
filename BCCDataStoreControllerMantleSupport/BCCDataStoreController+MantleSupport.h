//
//  BCCDataStoreController+MantleSupport.h
//
//  Created by Laurence Andersen on 10/28/15.
//  Copyright © 2015 Brooklyn Computer Club. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "BCCDataStoreController.h"

#ifdef MantleVersionNumber
#define BCCDataStoreControllerMantleSupport

#import <Mantle/Mantle.h>

@protocol BCCDataStoreControllerMantleObjectSerializing;


@interface BCCDataStoreController (MantleSupport)

// Entity Mass Creation

- (NSArray * _Nullable)createObjectsFromMantleObjectArray:(NSArray <MTLModel *> * _Nonnull)mantleObjectArray usingImportParameters:(BCCDataStoreControllerImportParameters * _Nonnull)importParameters;

- (NSManagedObject * _Nullable)createAndInsertObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject withGroupIdentifier:(NSString * _Nullable)groupIdentifier;

- (NSManagedObject * _Nullable)findOrCreateObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject groupIdentifier:(NSString * _Nullable)groupIdentifier;

// Query By Entity

- (NSArray *_Nullable)mantleObjectsOfClass:(Class _Nonnull)modelClass forGroupIdentifier:(NSString *_Nullable)groupIdentifier sortDescriptors:(NSArray *_Nullable)sortDescriptors;

- (NSArray *_Nullable)mantleObjectsOfClass:(Class _Nonnull)modelClass forGroupIdentifier:(NSString *_Nullable)groupIdentifier filteredByProperty:(NSString *_Nullable)propertyName valueSet:(NSSet *_Nullable)valueSet sortDescriptors:(NSArray *_Nullable)sortDescriptors;

// Observation

- (void)addObserver:(id _Nonnull)observer action:(SEL _Nonnull)action forMantleObjectOfClass:(Class <BCCDataStoreControllerMantleObjectSerializing> _Nonnull )mantleObjectClass;
- (void)addObserver:(id _Nonnull)observer action:(SEL _Nonnull)action forMantleObjectOfClass:(Class _Nonnull)mantleObjectClass withPredicate:(NSPredicate *_Nullable)predicate requiredChangedKeys:(NSArray * _Nullable)changedKeys;

- (BOOL)hasObserver:(id _Nonnull)observer forMantleObjectOfClass:(Class <BCCDataStoreControllerMantleObjectSerializing> _Nonnull)mantleObjectClass;

- (void)removeObserver:(id _Nonnull)observer forMantleObjectOfClass:(Class <BCCDataStoreControllerMantleObjectSerializing> _Nonnull )mantleObjectClass;

@end


@protocol BCCDataStoreControllerMantleObjectSerializing <MTLModel>

@required

+ (NSDictionary * _Nonnull)managedObjectKeysByPropertyKey;

+ (BCCDataStoreControllerIdentityParameters * _Nonnull)managedObjectIdentityParameters;

@optional

+ (NSValueTransformer * _Nonnull)entityAttributeTransformerForKey:(NSString * _Nonnull)key;

+ (NSDictionary * _Nonnull)relationshipModelClassesByPropertyKey;

+ (Class _Nonnull)classForDeserializingManagedObject:(NSManagedObject * _Nonnull)managedObject;

@end

#endif
