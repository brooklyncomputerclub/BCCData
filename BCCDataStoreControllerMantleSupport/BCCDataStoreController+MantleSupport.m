//
//  BCCDataStoreController+MantleSupport.m
//  Toilets
//
//  Created by Laurence Andersen on 10/28/15.
//  Copyright © 2015 Brooklyn Computer Club. All rights reserved.
//

#import "BCCDataStoreController+MantleSupport.h"
#import "BCCDataStoreController.h"


@implementation BCCDataStoreController (MantleSupport)

- (NSManagedObject * _Nullable)createAndInsertObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject identityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters
{
    if (!identityParameters.identityPropertyName) {
        return nil;
    }
    
    id identityValue = [mantleObject valueForKey:identityParameters.identityPropertyName];
    if (!identityValue) {
        return nil;
    }
    
    NSString *groupPropertyName = identityParameters.groupPropertyName;
    NSString *groupIdentifier = nil;
    if (groupPropertyName) {
        [mantleObject valueForKey:groupPropertyName];
    }
    
    return [self createAndInsertObjectWithIdentityParameters:identityParameters identityValue:identityValue groupIdentifier:groupIdentifier];
}

- (NSManagedObject * _Nullable)findOrCreateObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject identityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters
{
    NSString *identityPropertyName = identityParameters.identityPropertyName;
    
    if (!identityPropertyName) {
        return nil;
    }
    
    id identityValue = [mantleObject valueForKeyPath:identityPropertyName];
    if (!identityValue) {
        return nil;
    }
    
    NSManagedObject *object = [self findOrCreateObjectWithIdentityParameters:identityParameters identityValue:identityValue groupIdentifier:nil];
    
    return object;
}

// Entity Mass Creation
- (NSArray * _Nullable)createObjectsFromMantleObjectArray:(NSArray <MTLModel *> * _Nonnull)mantleObjectArray usingImportParameters:(BCCDataStoreControllerImportParameters * _Nonnull)importParameters identityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters postCreateBlock:(BCCDataStoreControllerPostCreateBlock _Nullable)postCreateBlock
{
    if (mantleObjectArray.count < 1) {
        return nil;
    }
    
    NSManagedObjectContext *managedObjectContext = [self currentMOC];
    
    BOOL findExisting = importParameters.findExisting;
    BOOL deleteExisting = importParameters.deleteExisting;
    
    if (importParameters.deleteExisting) {
        [self deleteObjectsWithIdentityParameters:identityParameters importParameters:importParameters];
    }

    NSString *groupIdentifier = importParameters.groupIdentifier;
    
    NSMutableArray *affectedObjects = [[NSMutableArray alloc] init];
    
    [mantleObjectArray enumerateObjectsUsingBlock:^(MTLModel<BCCDataStoreControllerMantleObjectSerializing> * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSManagedObject *affectedObject = nil;
        
        if (findExisting && !deleteExisting) {
            affectedObject = [self findOrCreateObjectWithMantleObject:obj identityParameters:identityParameters];
        } else {
            affectedObject = [self createAndInsertObjectWithMantleObject:obj identityParameters:identityParameters];
        }
        
        if (!affectedObject) {
            return;
        }
        
        NSString *groupPropertyName = identityParameters.groupPropertyName;
        if (groupIdentifier && groupPropertyName) {
            [affectedObject setValue:groupIdentifier forKey:groupPropertyName];
        }
        
        if (postCreateBlock) {
            postCreateBlock(affectedObject, obj, idx, managedObjectContext);
        }
        
        [affectedObjects addObject:affectedObject];
    }];
    
    return nil;
}

@end
