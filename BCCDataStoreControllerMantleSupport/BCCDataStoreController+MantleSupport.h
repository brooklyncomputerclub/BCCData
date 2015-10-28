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
- (NSManagedObject * _Nullable)createAndInsertObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject;

// Entity Find Or Create
- (NSManagedObject * _Nullable)findOrCreateObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject;

// Entity Mass Creation
- (NSArray * _Nullable)createObjectsFromMantleObjectArray:(NSArray <MTLModel <BCCDataStoreControllerMantleObjectSerializing> *> * _Nonnull)dictionaryArray usingImportParameters:(BCCDataStoreControllerImportParameters * _Nonnull)importParameters postCreateBlock:(BCCDataStoreControllerPostCreateBlock _Nullable)postCreateBlock;

@end


@protocol BCCDataStoreControllerMantleObjectSerializing <MTLModel>

@required

+ (BCCDataStoreControllerIdentityParameters * _Nonnull)BCC_identityParameters;

@end
