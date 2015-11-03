//
//  BCCDataStoreController+MantleSupport.m
//  Toilets
//
//  Created by Laurence Andersen on 10/28/15.
//  Copyright © 2015 Brooklyn Computer Club. All rights reserved.
//

#import "BCCDataStoreController+MantleSupport.h"
#import "BCCDataStoreController.h"


@interface BCCDataStoreController (MantleSupportPrivate)

// Serialization
- (void)updateManagedObject:(NSManagedObject * _Nonnull)managedObject usingModelObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)model error:(NSError **)error;

// Deserialization
- (void)updateMantleObject:(MTLModel * _Nonnull)model withManagedObject:(NSManagedObject * _Nonnull)managedObject error:(NSError **)error;

@end


@implementation BCCDataStoreController (MantleSupport)

#pragma mark -
#pragma mark - Entity Mass Creation

- (NSManagedObject * _Nullable)createAndInsertObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject withGroupIdentifier:(NSString * _Nullable)groupIdentifier
{
    BCCDataStoreControllerIdentityParameters *identityParameters = [[mantleObject class] managedObjectIdentityParameters];
    
    NSString *identityPropertyName = identityParameters.identityPropertyName;
    
    if (!identityPropertyName) {
        return nil;
    }
    
    id identityValue = [mantleObject valueForKeyPath:identityPropertyName];
    if (!identityValue) {
        return nil;
    }
    
    NSManagedObject *affectedObject = [self createAndInsertObjectWithIdentityParameters:identityParameters identityValue:identityValue groupIdentifier:groupIdentifier];
    if (affectedObject) {
        [self updateManagedObject:affectedObject usingModelObject:mantleObject error:NULL];
    }
    
    return affectedObject;
}

- (NSManagedObject * _Nullable)findOrCreateObjectWithMantleObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)mantleObject groupIdentifier:(NSString * _Nullable)groupIdentifier
{
    BCCDataStoreControllerIdentityParameters *identityParameters = [[mantleObject class] managedObjectIdentityParameters];
    
    NSString *identityPropertyName = identityParameters.identityPropertyName;
    
    if (!identityPropertyName) {
        return nil;
    }
    
    id identityValue = [mantleObject valueForKeyPath:identityPropertyName];
    if (!identityValue) {
        return nil;
    }
    
    NSManagedObject *affectedObject = [self findOrCreateObjectWithIdentityParameters:identityParameters identityValue:identityValue groupIdentifier:nil];
    if (affectedObject) {
        [self updateManagedObject:affectedObject usingModelObject:mantleObject error:NULL];
    }
    
    return affectedObject;
}

- (NSArray * _Nullable)createObjectsFromMantleObjectArray:(NSArray <MTLModel *> * _Nonnull)mantleObjectArray usingImportParameters:(BCCDataStoreControllerImportParameters * _Nonnull)importParameters postCreateBlock:(BCCDataStoreControllerPostCreateBlock _Nullable)postCreateBlock
{
    if (mantleObjectArray.count < 1) {
        return nil;
    }
    
    NSManagedObjectContext *managedObjectContext = [self currentMOC];
    
    NSString *groupIdentifier = importParameters.groupIdentifier;
    
    BOOL findExisting = importParameters.findExisting;
    BOOL deleteExisting = (groupIdentifier != nil) && importParameters.deleteExisting;
    
    NSMutableArray *affectedObjects = [[NSMutableArray alloc] init];
    NSMutableSet *entityGroupsAlreadyDeleted = [[NSMutableSet alloc] init];
    
    [mantleObjectArray enumerateObjectsUsingBlock:^(MTLModel<BCCDataStoreControllerMantleObjectSerializing> * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        BCCDataStoreControllerIdentityParameters *identityParameters = [[obj class] managedObjectIdentityParameters];
        NSString *entityName = identityParameters.entityName;
        
        if (!entityName) {
            return;
        }
        
        NSString *groupPropertyName = identityParameters.groupPropertyName;
        if (![entityGroupsAlreadyDeleted containsObject:entityName] && deleteExisting && groupPropertyName) {
            [self deleteObjectsWithIdentityParameters:identityParameters groupIdentifier:groupIdentifier];
            [entityGroupsAlreadyDeleted addObject:entityName];
        }
        
        NSManagedObject *affectedObject = nil;
        
        if (findExisting && !deleteExisting) {
            affectedObject = [self findOrCreateObjectWithMantleObject:obj groupIdentifier:groupIdentifier];
        } else {
            affectedObject = [self createAndInsertObjectWithMantleObject:obj withGroupIdentifier:groupIdentifier];;
        }
        
        if (!affectedObject) {
            return;
        }
        
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

#pragma mark -
#pragma mark Query By Entity

- (NSArray * _Nullable)mantleObjectsOfClass:(Class _Nonnull)modelClass forIdentityParameters:(BCCDataStoreControllerIdentityParameters * _Nonnull)identityParameters groupIdentifier:(NSString * _Nullable)groupIdentifier sortDescriptors:(NSArray * _Nullable)sortDescriptors
{
    return [self mantleObjectsOfClass:modelClass forIdentityParameters:identityParameters groupIdentifier:groupIdentifier filteredByProperty:nil valueSet:nil sortDescriptors:sortDescriptors];
}

- (NSArray *)mantleObjectsOfClass:(Class)modelClass forIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters groupIdentifier:(NSString *)groupIdentifier filteredByProperty:(NSString *)propertyName valueSet:(NSSet *)valueSet sortDescriptors:(NSArray *)sortDescriptors
{
    NSArray *affectedObjects = [self objectsForIdentityParameters:identityParameters groupIdentifier:groupIdentifier filteredByProperty:propertyName valueSet:valueSet sortDescriptors:sortDescriptors];
    
    NSMutableArray *mantleObjects = [[NSMutableArray alloc] init];
    
    [affectedObjects enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        MTLModel *model = [[modelClass alloc] init];
        [self updateMantleObject:model withManagedObject:obj error:NULL];
        [mantleObjects addObject:model];
    }];
    
    return mantleObjects;
}

#pragma mark -
#pragma mark Serialization

// Adapted from MTLManagedObjectAdapter
// https://github.com/Mantle/MTLManagedObjectAdapter/blob/master/MTLManagedObjectAdapter/MTLManagedObjectAdapter.m

- (void)updateManagedObject:(NSManagedObject * _Nonnull)managedObject usingModelObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)model error:(NSError **)error
{
    // Assign all errors to this variable to work around a memory problem.
    //
    // See https://github.com/github/Mantle/pull/120 for more context.
    __block NSError *tmpError;
    
    Class modelClass = [model class];
    NSDictionary *managedObjectKeysByPropertyKey = [modelClass managedObjectKeysByPropertyKey];

    NSDictionary *dictionaryValue = model.dictionaryValue;
    NSDictionary *managedObjectProperties = managedObject.entity.propertiesByName;
    
    NSEntityDescription *entity = managedObject.entity;
    NSAssert(entity != nil, @"%@ returned a nil +entity", managedObject);
    
    [dictionaryValue enumerateKeysAndObjectsUsingBlock:^(NSString *propertyKey, id value, BOOL *stop) {
        NSString *managedObjectKey = managedObjectKeysByPropertyKey[propertyKey];
        if (managedObjectKey == nil) return;
        if ([value isEqual:NSNull.null]) value = nil;
        
        BOOL (^serializeAttribute)(NSAttributeDescription *) = ^(NSAttributeDescription *attributeDescription) {
            // Mark this as being autoreleased, because validateValue may return
            // a new object to be stored in this variable (and we don't want ARC to
            // double-free or leak the old or new values).
            __autoreleasing id transformedValue = value;
            
            NSValueTransformer *transformer = [modelClass entityAttributeTransformerForKey:propertyKey];
            if ([transformer.class allowsReverseTransformation]) {
                if ([transformer respondsToSelector:@selector(reverseTransformedValue:success:error:)]) {
                    id<MTLTransformerErrorHandling> errorHandlingTransformer = (id)transformer;
                    
                    BOOL success = YES;
                    transformedValue = [errorHandlingTransformer reverseTransformedValue:value success:&success error:error];
                    
                    if (!success) return NO;
                } else {
                    transformedValue = [transformer reverseTransformedValue:transformedValue];
                }
            }
            
            if (![managedObject validateValue:&transformedValue forKey:managedObjectKey error:&tmpError]) return NO;
            [managedObject setValue:transformedValue forKey:managedObjectKey];
            
            return YES;
        };
        
        NSManagedObject * (^objectForRelationshipFromModel)(id) = ^ id (id model) {
            if (![model conformsToProtocol:@protocol(BCCDataStoreControllerMantleObjectSerializing)]) {
                /*NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Property of class %@ cannot be encoded into an NSManagedObject.", @""), [model class]];
                
                NSDictionary *userInfo = @{
                                           NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
                                           NSLocalizedFailureReasonErrorKey: failureReason
                                           };
                
                tmpError = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorUnsupportedRelationshipClass userInfo:userInfo];*/
                
                return nil;
            }
            
            BCCDataStoreControllerIdentityParameters *identityParameters = [[(MTLModel <BCCDataStoreControllerMantleObjectSerializing> *)model class] managedObjectIdentityParameters];
            
            id identityValue = [model valueForKey:identityParameters.identityPropertyName];
            
            NSString *groupIdentifier = nil;
            NSString *groupPropertyName = identityParameters.groupPropertyName;
            
            if (groupPropertyName) {
                [model valueForKey:groupPropertyName];
            }

            NSManagedObject *managedObject = [self findOrCreateObjectWithIdentityParameters:identityParameters identityValue:identityValue groupIdentifier:groupIdentifier];
            [self updateManagedObject:managedObject usingModelObject:model error:error];
            return managedObject;
        };
        
        BOOL (^serializeRelationship)(NSRelationshipDescription *) = ^(NSRelationshipDescription *relationshipDescription) {
            if (value == nil) return YES;
            
            if ([relationshipDescription isToMany]) {
                if (![value conformsToProtocol:@protocol(NSFastEnumeration)]) {
                    /*NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Property of class %@ cannot be encoded into a to-many relationship.", @""), [value class]];
                    
                    NSDictionary *userInfo = @{
                                               NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
                                               NSLocalizedFailureReasonErrorKey: failureReason
                                               };
                    
                    tmpError = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorUnsupportedRelationshipClass userInfo:userInfo];*/
                    
                    return NO;
                }
                
                id relationshipCollection;
                if ([relationshipDescription isOrdered]) {
                    relationshipCollection = [NSMutableOrderedSet orderedSet];
                } else {
                    relationshipCollection = [NSMutableSet set];
                }
                
                for (id<MTLModel> model in value) {
                    NSManagedObject *nestedObject = objectForRelationshipFromModel(model);
                    if (nestedObject == nil) return NO;
                    
                    [relationshipCollection addObject:nestedObject];
                }
                
                [managedObject setValue:relationshipCollection forKey:managedObjectKey];
            } else {
                NSManagedObject *nestedObject = objectForRelationshipFromModel(value);
                if (nestedObject == nil) return NO;
                
                [managedObject setValue:nestedObject forKey:managedObjectKey];
            }
            
            return YES;
        };
        
        BOOL (^serializeProperty)(NSPropertyDescription *) = ^(NSPropertyDescription *propertyDescription) {
            if (propertyDescription == nil) {
                /*NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"No property by name \"%@\" exists on the entity.", @""), managedObjectKey];
                
                NSDictionary *userInfo = @{
                                           NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
                                           NSLocalizedFailureReasonErrorKey: failureReason
                                           };
                
                tmpError = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorInvalidManagedObjectKey userInfo:userInfo];*/
                
                return NO;
            }
            
            // Jump through some hoops to avoid referencing classes directly.
            NSString *propertyClassName = NSStringFromClass(propertyDescription.class);
            if ([propertyClassName isEqual:@"NSAttributeDescription"]) {
                return serializeAttribute((id)propertyDescription);
            } else if ([propertyClassName isEqual:@"NSRelationshipDescription"]) {
                return serializeRelationship((id)propertyDescription);
            } else {
                /*NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Property descriptions of class %@ are unsupported.", @""), propertyClassName];
                
                NSDictionary *userInfo = @{
                                           NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
                                           NSLocalizedFailureReasonErrorKey: failureReason
                                           };
                
                tmpError = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorUnsupportedManagedObjectPropertyType userInfo:userInfo];*/
                
                return NO;
            }
        };
        
        if (!serializeProperty(managedObjectProperties[managedObjectKey])) {
            *stop = YES;
        }
    }];
    
    if (error != NULL) {
        *error = tmpError;
    }
}

#pragma mark - Deserialization

// Adapted from MTLManagedObjectAdapter
// https://github.com/Mantle/MTLManagedObjectAdapter/blob/master/MTLManagedObjectAdapter/MTLManagedObjectAdapter.m
// - (id)modelFromManagedObject:(NSManagedObject *)managedObject processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error

- (void)updateMantleObject:(MTLModel * _Nonnull)model withManagedObject:(NSManagedObject * _Nonnull)managedObject error:(NSError **)error
{
    Class modelClass = [model class];
    NSDictionary *managedObjectKeysByPropertyKey = [modelClass managedObjectKeysByPropertyKey];
    
    NSEntityDescription *entity = managedObject.entity;
    NSAssert(entity != nil, @"%@ returned a nil +entity", managedObject);
    
    NSDictionary *managedObjectProperties = entity.propertiesByName;
    
    BOOL (^setValueForKey)(NSString *, id) = ^(NSString *key, id value) {
        // Mark this as being autoreleased, because validateValue may return
        // a new object to be stored in this variable (and we don't want ARC to
        // double-free or leak the old or new values).
        __autoreleasing id replaceableValue = value;
        if (![model validateValue:&replaceableValue forKey:key error:error]) return NO;
        
        [model setValue:replaceableValue forKey:key];
        
        return YES;
    };
    
    for (NSString *propertyKey in [modelClass propertyKeys]) {
        NSString *managedObjectKey = managedObjectKeysByPropertyKey[propertyKey];
        if (managedObjectKey == nil) continue;
        
        
        BOOL (^deserializeAttribute)(NSAttributeDescription *) = ^(NSAttributeDescription *attributeDescription) {
            id value = [managedObject valueForKey:managedObjectKey];
            
            NSValueTransformer *transformer = [modelClass entityAttributeTransformerForKey:propertyKey];
            
            if ([transformer respondsToSelector:@selector(transformedValue:success:error:)]) {
                id<MTLTransformerErrorHandling> errorHandlingTransformer = (id)transformer;

                BOOL success = YES;
                value = [errorHandlingTransformer transformedValue:value success:&success error:error];
                
                if (!success) return NO;
            } else if (transformer != nil) {
                value = [transformer transformedValue:value];
            }
            
            return setValueForKey(propertyKey, value);
        };
        
        BOOL (^deserializeProperty)(NSPropertyDescription *) = ^(NSPropertyDescription *propertyDescription) {
            if (propertyDescription == nil) {
                if (error != NULL) {
                    /*NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"No property by name \"%@\" exists on the entity.", @""), managedObjectKey];

                    NSDictionary *userInfo = @{
                                               NSLocalizedDescriptionKey: NSLocalizedString(@"Could not deserialize managed object", @""),
                                               NSLocalizedFailureReasonErrorKey: failureReason,
                                               };

                    *error = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorInvalidManagedObjectKey userInfo:userInfo];*/
                }

                return NO;
            }

            // Jump through some hoops to avoid referencing classes directly.
            NSString *propertyClassName = NSStringFromClass(propertyDescription.class);
            
            if ([propertyClassName isEqual:@"NSAttributeDescription"]) {
                return deserializeAttribute((id)propertyDescription);
            } else if ([propertyClassName isEqual:@"NSRelationshipDescription"]) {
                return NO;
                //return deserializeRelationship((id)propertyDescription);
            } else {
                if (error != NULL) {
                    /*NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Property descriptions of class %@ are unsupported.", @""), propertyClassName];
                    
                    NSDictionary *userInfo = @{
                                               NSLocalizedDescriptionKey: NSLocalizedString(@"Could not deserialize managed object", @""),
                                               NSLocalizedFailureReasonErrorKey: failureReason,
                                               };

                    *error = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorUnsupportedManagedObjectPropertyType userInfo:userInfo];*/
                }
                
                return NO;
            }
        };

        if (!deserializeProperty(managedObjectProperties[managedObjectKey])) return;
    }
}

@end
