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

// Entity CRUD
- (NSManagedObject * _Nullable)createAndInsertObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject identityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters;

// Entity Find Or Create
- (NSManagedObject * _Nullable)findOrCreateObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject identityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters;

// Entity Mass Creation
- (NSArray * _Nullable)createObjectsFromMantleObjectArray:(NSArray <MTLModel *> * _Nonnull)mantleObjectArray usingImportParameters:(BCCDataStoreControllerImportParameters * _Nonnull)importParameters identityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters postCreateBlock:(BCCDataStoreControllerPostCreateBlock _Nullable)postCreateBlock;

@end