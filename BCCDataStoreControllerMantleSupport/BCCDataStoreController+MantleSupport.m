//
//  BCCDataStoreController+MantleSupport.m
//  Toilets
//
//  Created by Laurence Andersen on 10/28/15.
//  Copyright © 2015 Brooklyn Computer Club. All rights reserved.
//

#import "BCCDataStoreController+MantleSupport.h"
#import "BCCDataStoreController.h"

#ifdef BCCDataStoreControllerMantleSupport

NSString * const BCCDataStoreControllerMantleSupportErrorDomain = @"BCCDataStoreControllerMantleSupportErrorDomain";
const NSInteger BCCDataStoreControllerMantleSupportErrorNoClassFound = 2;
const NSInteger BCCDataStoreControllerMantleSupportErrorInitializationFailed = 3;
const NSInteger BCCDataStoreControllerMantleSupportErrorInvalidManagedObjectKey = 4;
const NSInteger BCCDataStoreControllerMantleSupportErrorUnsupportedManagedObjectPropertyType = 5;
const NSInteger BCCDataStoreControllerMantleSupportErrorUnsupportedRelationshipClass = 6;
const NSInteger BCCDataStoreControllerMantleSupportErrorUniqueFetchRequestFailed = 7;
const NSInteger BCCDataStoreControllerMantleSupportErrorInvalidManagedObjectMapping = 8;


@interface BCCDataStoreController (MantleSupportPrivate)

// Serialization
- (void)updateManagedObject:(NSManagedObject * _Nonnull)managedObject usingModelObject:(MTLModel <BCCDataStoreControllerMantleObjectSerializing> * _Nonnull)model error:(NSError **)error;

// Deserialization
- (id)mantleObjectOfClass:(Class)modelClass fromManagedObject:(NSManagedObject *)managedObject processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error;
- (void)updateMantleObject:(MTLModel * _Nonnull)model withManagedObject:(NSManagedObject * _Nonnull)managedObject processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error;

@end


@implementation BCCDataStoreController (MantleSupport)

#pragma mark - Entity Mass Creation
#pragma mark -

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

- (NSArray * _Nullable)createObjectsFromMantleObjectArray:(NSArray <MTLModel *> * _Nonnull)mantleObjectArray usingImportParameters:(BCCDataStoreControllerImportParameters * _Nonnull)importParameters
{
    if (mantleObjectArray.count < 1) {
        return nil;
    }
    
    NSManagedObjectContext *managedObjectContext = [self currentMOC];
    
    NSString *groupIdentifier = importParameters.groupIdentifier;
    
    BOOL findExisting = importParameters.findExisting;
    BOOL deleteExisting = importParameters.deleteExisting;
    
    NSMutableArray *affectedObjects = [[NSMutableArray alloc] init];
    NSMutableSet *entityGroupsAlreadyDeleted = [[NSMutableSet alloc] init];
    
    [mantleObjectArray enumerateObjectsUsingBlock:^(MTLModel<BCCDataStoreControllerMantleObjectSerializing> * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        BCCDataStoreControllerIdentityParameters *identityParameters = [[obj class] managedObjectIdentityParameters];
        NSString *entityName = identityParameters.entityName;
        
        if (!entityName) {
            return;
        }
        
        NSString *groupPropertyName = identityParameters.groupPropertyName;
        
        if (deleteExisting && ![entityGroupsAlreadyDeleted containsObject:entityName]) {
            if (groupPropertyName) {
                [self deleteObjectsWithIdentityParameters:identityParameters groupIdentifier:groupIdentifier];
            } else {
                [self deleteObjectsWithEntityName:entityName];
            }
            
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
        
        NSString *listIndexPropertyName = identityParameters.listIndexPropertyName;
        if (listIndexPropertyName) {
            [affectedObject setValue:@(idx) forKey:listIndexPropertyName];
        }
        
        if (importParameters.postCreateBlock) {
            importParameters.postCreateBlock(affectedObject, obj, idx, managedObjectContext);
        }
        
        [affectedObjects addObject:affectedObject];
    }];
    
    return nil;
}

#pragma mark - Query By Entity
#pragma mark -

- (NSArray *_Nullable)mantleObjectsOfClass:(Class _Nonnull)modelClass forGroupIdentifier:(NSString *_Nullable)groupIdentifier sortDescriptors:(NSArray *_Nullable)sortDescriptors
{
    return [self mantleObjectsOfClass:modelClass forGroupIdentifier:groupIdentifier filteredByProperty:nil valueSet:nil sortDescriptors:sortDescriptors];
}

- (NSArray *)mantleObjectsOfClass:(Class)modelClass forGroupIdentifier:(NSString *)groupIdentifier filteredByProperty:(NSString *)propertyName valueSet:(NSSet *)valueSet sortDescriptors:(NSArray *)sortDescriptors
{
    if (![modelClass conformsToProtocol:@protocol(BCCDataStoreControllerMantleObjectSerializing)]) {
        return nil;
    }
    
    BCCDataStoreControllerIdentityParameters *identityParameters = [modelClass managedObjectIdentityParameters];
    if (!identityParameters) {
        return nil;
    }
    
    NSArray *affectedObjects = [self objectsForIdentityParameters:identityParameters groupIdentifier:groupIdentifier filteredByProperty:propertyName valueSet:valueSet sortDescriptors:sortDescriptors];
    
    NSMutableArray *mantleObjects = [[NSMutableArray alloc] init];
    
    CFMutableDictionaryRef processedObjects = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (processedObjects == NULL) return nil;
    
    [affectedObjects enumerateObjectsUsingBlock:^(id _Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
        MTLModel *model = [self mantleObjectOfClass:modelClass fromManagedObject:obj processedObjects:processedObjects error:NULL];
        [mantleObjects addObject:model];
    }];
    
    CFRelease(processedObjects);
    
    return mantleObjects;
}

#pragma mark - Serialization
#pragma mark -

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
            
            NSValueTransformer *transformer = nil;
            
            if ([modelClass instancesRespondToSelector:@selector(entityAttributeTransformerForKey:)]) {
                transformer = [modelClass entityAttributeTransformerForKey:propertyKey];
            }
            
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
                NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Property of class %@ cannot be encoded into an NSManagedObject.", @""), [model class]];
                
                NSDictionary *userInfo = @{
                                           NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
                                           NSLocalizedFailureReasonErrorKey: failureReason
                                           };
                
                tmpError = [NSError errorWithDomain:BCCDataStoreControllerMantleSupportErrorDomain code:BCCDataStoreControllerMantleSupportErrorUnsupportedRelationshipClass userInfo:userInfo];
                
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
                    NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Property of class %@ cannot be encoded into a to-many relationship.", @""), [value class]];
                    
                    NSDictionary *userInfo = @{
                                               NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
                                               NSLocalizedFailureReasonErrorKey: failureReason
                                               };
                    
                    tmpError = [NSError errorWithDomain:BCCDataStoreControllerMantleSupportErrorDomain code:BCCDataStoreControllerMantleSupportErrorUnsupportedRelationshipClass userInfo:userInfo];
                    
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
                NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"No property by name \"%@\" exists on the entity.", @""), managedObjectKey];
                
                NSDictionary *userInfo = @{
                                           NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
                                           NSLocalizedFailureReasonErrorKey: failureReason
                                           };
                
                tmpError = [NSError errorWithDomain:BCCDataStoreControllerMantleSupportErrorDomain code:BCCDataStoreControllerMantleSupportErrorInvalidManagedObjectKey userInfo:userInfo];
                
                return NO;
            }
            
            // Jump through some hoops to avoid referencing classes directly.
            NSString *propertyClassName = NSStringFromClass(propertyDescription.class);
            if ([propertyClassName isEqual:@"NSAttributeDescription"]) {
                return serializeAttribute((id)propertyDescription);
            } else if ([propertyClassName isEqual:@"NSRelationshipDescription"]) {
                return serializeRelationship((id)propertyDescription);
            } else {
                NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Property descriptions of class %@ are unsupported.", @""), propertyClassName];
                
                NSDictionary *userInfo = @{
                                           NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
                                           NSLocalizedFailureReasonErrorKey: failureReason
                                           };
                
                tmpError = [NSError errorWithDomain:BCCDataStoreControllerMantleSupportErrorDomain code:BCCDataStoreControllerMantleSupportErrorUnsupportedManagedObjectPropertyType userInfo:userInfo];
                
                return NO;
            }
        };
        
        serializeProperty(managedObjectProperties[managedObjectKey]);
    }];
    
    if (error != NULL) {
        *error = tmpError;
    }
}

#pragma mark - Deserialization
#pragma mark -

// Adapted from MTLManagedObjectAdapter
// https://github.com/Mantle/MTLManagedObjectAdapter/blob/master/MTLManagedObjectAdapter/MTLManagedObjectAdapter.m
// + (id)modelOfClass:(Class)modelClass fromManagedObject:(NSManagedObject *)managedObject processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error

- (id)mantleObjectOfClass:(Class)modelClass fromManagedObject:(NSManagedObject *)managedObject processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error
{
    NSParameterAssert(modelClass != nil);
    NSParameterAssert(processedObjects != nil);
    
    if (managedObject == nil) return nil;
    
    const void *existingModel = CFDictionaryGetValue(processedObjects, (__bridge void *)managedObject);
    if (existingModel != NULL) {
        return (__bridge id)existingModel;
    }
    
    if ([modelClass respondsToSelector:@selector(classForDeserializingManagedObject:)]) {
        modelClass = [modelClass classForDeserializingManagedObject:managedObject];
        if (modelClass == nil) {
            if (error != NULL) {
                NSDictionary *userInfo = @{
                                           NSLocalizedDescriptionKey: NSLocalizedString(@"Could not deserialize managed object", @""),
                                           NSLocalizedFailureReasonErrorKey: NSLocalizedString(@"No model class could be found to deserialize the object.", @"")
                                           };
             
                *error = [NSError errorWithDomain:BCCDataStoreControllerMantleSupportErrorDomain code:BCCDataStoreControllerMantleSupportErrorNoClassFound userInfo:userInfo];
             }
            
            return nil;
        }
    }
    
    id model = [[modelClass alloc] init];
    
    // Pre-emptively consider this object processed, so that we don't get into
    // any cycles when processing its relationships.
    CFDictionaryAddValue(processedObjects, (__bridge void *)managedObject, (__bridge void *)model);
    
    [self updateMantleObject:model withManagedObject:managedObject processedObjects:processedObjects error:error];
    
    return model;
}

// Adapted from MTLManagedObjectAdapter
// https://github.com/Mantle/MTLManagedObjectAdapter/blob/master/MTLManagedObjectAdapter/MTLManagedObjectAdapter.m
// - (id)modelFromManagedObject:(NSManagedObject *)managedObject processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error

- (void)updateMantleObject:(MTLModel * _Nonnull)model withManagedObject:(NSManagedObject * _Nonnull)managedObject processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error
{
    if (processedObjects == NULL) return;
    
    Class modelClass = [model class];
    NSDictionary *managedObjectKeysByPropertyKey = [modelClass managedObjectKeysByPropertyKey];
    
    NSDictionary *relationshipModelClassesByPropertyKey = nil;
    if ([modelClass respondsToSelector:@selector(relationshipModelClassesByPropertyKey)]) {
        relationshipModelClassesByPropertyKey = [modelClass relationshipModelClassesByPropertyKey];
    }
    
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
            
            NSValueTransformer *transformer = nil;
            
            if ([modelClass instancesRespondToSelector:@selector(entityAttributeTransformerForKey:)]) {
                transformer = [modelClass entityAttributeTransformerForKey:propertyKey];
            }
            
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
        
        BOOL (^deserializeRelationship)(NSRelationshipDescription *) = ^(NSRelationshipDescription *relationshipDescription) {
            
            NSString *nestedClassName = relationshipModelClassesByPropertyKey[propertyKey];
            if (!nestedClassName) {
                return NO;
            }
            
            Class nestedClass = NSClassFromString(nestedClassName);
            
            if (nestedClass == nil) {
                [NSException raise:NSInvalidArgumentException format:@"No class specified for decoding relationship at key \"%@\" in managed object %@", managedObjectKey, managedObject];
            }

            if ([relationshipDescription isToMany]) {
                id relationshipCollection = [managedObject valueForKey:managedObjectKey];
                id models = [NSMutableArray arrayWithCapacity:[relationshipCollection count]];

                for (NSManagedObject *nestedObject in relationshipCollection) {
                    MTLModel *model = [self mantleObjectOfClass:nestedClass fromManagedObject:nestedObject processedObjects:processedObjects error:error];
                    [models addObject:model];
                }

                if (models == nil) return NO;
                
                if (![relationshipDescription isOrdered]) models = [NSSet setWithArray:models];

                return setValueForKey(propertyKey, models);
            } else {
                NSManagedObject *nestedObject = [managedObject valueForKey:managedObjectKey];
                
                if (nestedObject == nil) return YES;

                MTLModel *model = [self mantleObjectOfClass:nestedClass fromManagedObject:nestedObject processedObjects:processedObjects error:error];
                
                if (model == nil) return NO;
                
                return setValueForKey(propertyKey, model);
            }
        };
        
        BOOL (^deserializeProperty)(NSPropertyDescription *) = ^(NSPropertyDescription *propertyDescription) {
            if (propertyDescription == nil) {
                if (error != NULL) {
                    NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"No property by name \"%@\" exists on the entity.", @""), managedObjectKey];

                    NSDictionary *userInfo = @{
                                               NSLocalizedDescriptionKey: NSLocalizedString(@"Could not deserialize managed object", @""),
                                               NSLocalizedFailureReasonErrorKey: failureReason,
                                               };

                    *error = [NSError errorWithDomain:BCCDataStoreControllerMantleSupportErrorDomain code:BCCDataStoreControllerMantleSupportErrorInvalidManagedObjectKey userInfo:userInfo];
                }

                return NO;
            }

            // Jump through some hoops to avoid referencing classes directly.
            NSString *propertyClassName = NSStringFromClass(propertyDescription.class);
            
            if ([propertyClassName isEqual:@"NSAttributeDescription"]) {
                return deserializeAttribute((id)propertyDescription);
            } else if ([propertyClassName isEqual:@"NSRelationshipDescription"]) {
                return deserializeRelationship((id)propertyDescription);
            } else {
                if (error != NULL) {
                    NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Property descriptions of class %@ are unsupported.", @""), propertyClassName];
                    
                    NSDictionary *userInfo = @{
                                               NSLocalizedDescriptionKey: NSLocalizedString(@"Could not deserialize managed object", @""),
                                               NSLocalizedFailureReasonErrorKey: failureReason,
                                               };

                    *error = [NSError errorWithDomain:BCCDataStoreControllerMantleSupportErrorDomain code:BCCDataStoreControllerMantleSupportErrorUnsupportedManagedObjectPropertyType userInfo:userInfo];
                }
                
                return NO;
            }
        };

        deserializeProperty(managedObjectProperties[managedObjectKey]);
    }
}

#pragma mark - Observation -

- (void)addObserver:(id _Nonnull)observer action:(SEL _Nonnull)action forMantleObjectOfClass:(Class <BCCDataStoreControllerMantleObjectSerializing> _Nonnull )mantleObjectClass
{
    [self addObserver:observer action:action forMantleObjectOfClass:mantleObjectClass withPredicate:nil requiredChangedKeys:nil];
}

- (void)addObserver:(id _Nonnull)observer action:(SEL _Nonnull)action forMantleObjectOfClass:(Class <BCCDataStoreControllerMantleObjectSerializing> _Nonnull )mantleObjectClass withPredicate:(NSPredicate *_Nullable)predicate requiredChangedKeys:(NSArray * _Nullable)changedKeys
{
    BCCDataStoreControllerIdentityParameters *identityParameters = [mantleObjectClass managedObjectIdentityParameters];
    NSString *entityName = identityParameters.entityName;
    if (!entityName) {
        NSParameterAssert(entityName != nil);
    }
    
    [self addObserver:observer action:action forEntityName:entityName withPredicate:predicate requiredChangedKeys:changedKeys];
}

- (BOOL)hasObserver:(id _Nonnull)observer forMantleObjectOfClass:(Class <BCCDataStoreControllerMantleObjectSerializing> _Nonnull)mantleObjectClass
{
    BCCDataStoreControllerIdentityParameters *identityParameters = [mantleObjectClass managedObjectIdentityParameters];
    NSString *entityName = identityParameters.entityName;
    if (!entityName) {
        NSParameterAssert(entityName != nil);
    }
    
    return [self hasObserver:observer forEntityName:entityName];
}

- (void)removeObserver:(id _Nonnull)observer forMantleObjectOfClass:(Class <BCCDataStoreControllerMantleObjectSerializing> _Nonnull )mantleObjectClass
{
    BCCDataStoreControllerIdentityParameters *identityParameters = [mantleObjectClass managedObjectIdentityParameters];
    NSString *entityName = identityParameters.entityName;
    if (!entityName) {
        NSParameterAssert(entityName != nil);
    }
    
    [self removeObserver:observer forEntityName:entityName];
}

@end

#endif
