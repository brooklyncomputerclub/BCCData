//
//  BCCDataStoreController.h
//
//  Created by Buzz Andersen on 3/24/11.
//  Copyright 2013 Brooklyn Computer Club. All rights reserved.
//
//  Version 3.0


#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class BCCTargetActionQueue;
@class BCCDataStoreController;
@class BCCDataStoreControllerIdentityParameters;
@class BCCDataStoreControllerWorkParameters;
@class BCCDataStoreControllerImportParameters;


extern NSString *BCCDataStoreControllerWillClearDatabaseNotification;
extern NSString *BCCDataStoreControllerDidClearDatabaseNotification;

extern NSString *BCCDataStoreControllerWillClearIncompatibleDatabaseNotification;
extern NSString *BCCDataStoreControllerDidClearIncompatibleDatabaseNotification;

typedef void (^BCCDataStoreControllerWorkBlock)(BCCDataStoreController *dataStoreController, NSManagedObjectContext *managedObjectContext, BCCDataStoreControllerWorkParameters *workParameters);

typedef void (^BCCDataStoreControllerPostCreateBlock)(NSManagedObject *createdObject, id sourceObject, NSUInteger idx, NSManagedObjectContext *managedObjectContext);

typedef enum {
    BCCDataStoreControllerWorkExecutionStyleMainMOCAndWait,
    BCCDataStoreControllerWorkExecutionStyleMainMOC,
    BCCDataStoreControllerWorkExecutionStyleBackgroundMOCAndWait,
    BCCDataStoreControllerWorkExecutionStyleBackgroundMOC,
    BCCDataStoreControllerWorkExecutionStyleThreadMOCAndWait,
    BCCDataStoreControllerWorkExecutionStyleThreadMOC
} BCCDataStoreControllerWorkExecutionStyle;


@interface BCCDataStoreController : NSObject {
    
}

@property (strong, nonatomic) NSString *managedObjectModelPath;

@property (strong, nonatomic) NSString *identifier;
@property (strong, nonatomic, readonly) NSString *rootDirectory;

@property (strong, nonatomic, readonly) NSManagedObjectModel *managedObjectModel;

@property (strong, nonatomic, readonly) NSManagedObjectContext *mainMOC;
@property (strong, nonatomic, readonly) NSManagedObjectContext *backgroundMOC;

// Class Methods
+ (NSString *)defaultRootDirectory;

// Initialization
- (id)initWithIdentifier:(NSString *)identifier modelPath:(NSString *)modelPath;
- (id)initWithIdentifier:(NSString *)identifier modelPath:(NSString *)modelPath rootDirectory:(NSString *)rootDirectory;

// Persistent Store State
- (void)reset;
- (void)deletePersistentStore;

// Managed Object Contexts
- (NSManagedObjectContext *)newMOCWithConcurrencyType:(NSManagedObjectContextConcurrencyType)concurrencyType;
- (NSManagedObjectContext *)currentMOC;

// Saving
- (void)saveCurrentMOC;
- (void)saveMainMOC;
- (void)saveBackgroundMOC;

// Work Queueing
- (void)performWorkWithParameters:(BCCDataStoreControllerWorkParameters *)importParameters;

- (void)performBlockOnMainMOC:(BCCDataStoreControllerWorkBlock)block;
- (void)performBlockOnMainMOCAndWait:(BCCDataStoreControllerWorkBlock)block;
- (void)performBlockOnMainMOC:(BCCDataStoreControllerWorkBlock)block afterDelay:(NSTimeInterval)delay;

- (void)performBlockOnBackgroundMOC:(BCCDataStoreControllerWorkBlock)block;
- (void)performBlockOnBackgroundMOCAndWait:(BCCDataStoreControllerWorkBlock)block;
- (void)performBlockOnBackgroundMOC:(BCCDataStoreControllerWorkBlock)block afterDelay:(NSTimeInterval)delay;

- (void)performBlockOnThreadMOC:(BCCDataStoreControllerWorkBlock)block;
- (void)performBlockOnThreadMOCAndWait:(BCCDataStoreControllerWorkBlock)block;

// Worker Context Memory Cache
- (void)setCacheObject:(NSManagedObject *)cacheObject forMOC:(NSManagedObjectContext *)managedObjectContext identityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters;
- (NSManagedObject *)cacheObjectForMOC:(NSManagedObjectContext *)managedObjectContext identityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier;
- (void)removeCacheObjectForMOC:(NSManagedObjectContext *)managedObjectContext identityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier;

// Entity Creation/Updates
- (NSManagedObject *)createAndInsertObjectWithEntityName:(NSString *)entityName;
- (NSManagedObject *)createAndInsertObjectWithIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier;

// Entity Find Or Create
- (NSManagedObject *)findOrCreateObjectWithIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier;

// Entity Deletion
- (void)deleteObjects:(NSArray *)affectedObjects;
- (void)deleteObjectsWithEntityName:(NSString *)entityName;
- (void)deleteObjectsWithIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters groupIdentifier:(NSString *)groupIdentifer;
- (void)deleteObjectWithIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier;

// Query by Entity
- (NSArray *)objectsForEntityWithName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors;

- (NSArray *)objectsForIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters groupIdentifier:(NSString *)groupIdentifier sortDescriptors:(NSArray *)sortDescriptors;
- (NSArray *)objectsForIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters groupIdentifier:(NSString *)groupIdentifier filteredByProperty:(NSString *)propertyName valueSet:(NSSet *)valueSet sortDescriptors:(NSArray *)sortDescriptors;

// Fetch Request Creation
- (NSFetchRequest *)fetchRequestForEntityName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors;

- (NSFetchRequest *)fetchRequestForIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier sortDescriptors:(NSArray *)sortDescriptors;
- (NSFetchRequest *)fetchRequestForIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValueList:(NSArray *)identityValues groupIdentifier:(NSString *)groupIdentifier sortDescriptors:(NSArray *)sortDescriptors;

- (NSFetchRequest *)fetchRequestForEntityName:(NSString *)entityName usingPropertyList:(NSArray *)propertyList valueList:(NSArray *)valueList sortDescriptors:(NSArray *)sortDescriptors;

- (NSFetchRequest *)fetchRequestForTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary sortDescriptors:(NSArray *)sortDescriptors;

// Fetching
- (NSManagedObject *)performSingleResultFetchForIdentityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier error:(NSError **)error;
- (NSManagedObject *)performSingleResultFetchOfEntityWithName:(NSString *)entityName usingPropertyList:(NSArray *)propertyList valueList:(NSArray *)valueList error:(NSError **)error;
- (NSManagedObject *)performSingleResultFetchRequest:(NSFetchRequest *)fetchRequest error:(NSError **)error;

- (NSArray *)performFetchOfEntityWithName:(NSString *)entityName usingPropertyList:(NSArray *)propertyList valueList:(NSArray *)valueList sortDescriptors:(NSArray *)sortDescriptors error:(NSError **)error;

- (NSArray *)performFetchRequest:(NSFetchRequest *)fetchRequest error:(NSError **)error;

// Fetching Using Templates
- (NSArray *)performFetchRequestWithTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary sortDescriptors:(NSArray *)sortDescriptors error:(NSError **)error;
- (NSManagedObject *)performSingleResultFetchRequestWithTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary error:(NSError **)error;

// Change Observation
- (void)addObserver:(id)observer action:(SEL)action forEntityName:(NSString *)entityName;
- (void)addObserver:(id)observer action:(SEL)action forEntityName:(NSString *)entityName withPredicate:(NSPredicate *)predicate requiredChangedKeys:(NSArray *)changedKeys;

- (BOOL)hasObserver:(id)observer;
- (BOOL)hasObserver:(id)observer forEntityName:(NSString *)entityName;

- (void)removeObserver:(id)observer;
- (void)removeObserver:(id)observer forEntityName:(NSString *)entityName;

@end


@interface BCCDataStoreController (JSONSupport)

// Entity Mass Creation
- (NSArray *)createObjectsFromJSONArray:(NSArray *)dictionaryArray usingImportParameters:(BCCDataStoreControllerImportParameters *)importParameters identityParameters:(BCCDataStoreControllerIdentityParameters *)identityParameters;

@end


@interface BCCDataStoreChangeNotification : NSObject

@property (strong, nonatomic) NSSet *updatedObjects;
@property (strong, nonatomic) NSSet *insertedObjects;
@property (strong, nonatomic) NSSet *deletedObjects;

- (id)initWithDictionary:(NSDictionary *)dictionary;

@end


@interface BCCDataStoreControllerWorkParameters : NSObject

@property (nonatomic) BCCDataStoreControllerWorkExecutionStyle workExecutionStyle;
@property (nonatomic) BOOL shouldSave;
@property (nonatomic) NSTimeInterval executionDelay;

@property (copy) BCCDataStoreControllerWorkBlock workBlock;
@property (copy) BCCDataStoreControllerWorkBlock postSaveBlock;

@end


@interface BCCDataStoreControllerIdentityParameters : NSObject

@property (strong, nonatomic) NSString *entityName;
@property (strong, nonatomic) NSString *identityPropertyName;
@property (strong, nonatomic) NSString *groupPropertyName;
@property (strong, nonatomic) NSString *listIndexPropertyName;

// Class Methods
+ (instancetype)identityParametersWithEntityName:(NSString *)entityName identityPropertyName:(NSString *)identityPropertyName;
+ (instancetype)identityParametersWithEntityName:(NSString *)entityName groupPropertyName:(NSString *)groupPropertyName;

// Initialization
- (instancetype)initWithEntityName:(NSString *)entityName;

@end


@interface BCCDataStoreControllerImportParameters : NSObject

@property (nonatomic) BOOL findExisting;
@property (nonatomic) BOOL deleteExisting;

@property (strong, nonatomic) NSString *dictionaryIdentityPropertyName;

@property (strong, nonatomic) NSString *groupIdentifier;

@property (copy) BCCDataStoreControllerPostCreateBlock postCreateBlock;

@end



@interface BCCDataStoreController (Deprecated)

// ---------------- DEPRECATED ----------------

// Worker Context Memory Cache
- (void)setCacheObject:(NSManagedObject *)cacheObject forMOC:(NSManagedObjectContext *)managedObjectContext entityName:(NSString *)entityName identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier __attribute__((deprecated));
- (NSManagedObject *)cacheObjectForMOC:(NSManagedObjectContext *)managedObjectContext entityName:(NSString *)entityName identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier __attribute__((deprecated));
- (void)removeCacheObjectForMOC:(NSManagedObjectContext *)managedObjectContext entityName:(NSString *)entityName identityValue:(id)identityValue groupIdentifier:(NSString *)groupIdentifier __attribute__((deprecated));

// Entity Creation/Updates
- (NSManagedObject *)createAndInsertObjectWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier __attribute__((deprecated));

- (NSManagedObject *)findOrCreateObjectWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier __attribute__((deprecated));

// Entity Mass Creation
- (NSArray *)createObjectsOfEntityType:(NSString *)entityName fromDictionaryArray:(NSArray *)dictionaryArray findExisting:(BOOL)findExisting dictionaryIdentityProperty:(NSString *)dictionaryIdentityPropertyName modelIdentityProperty:(NSString *)modelIdentityPropertyName groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier postCreateBlock:(BCCDataStoreControllerPostCreateBlock)postCreateBlock __attribute__((deprecated));

// Entity Deletion
- (void)deleteObjectsWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier __attribute__((deprecated));

// Query by Entity
- (NSArray *)objectsForEntityWithName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier __attribute__((deprecated));
- (NSArray *)objectsForEntityWithName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier filteredByProperty:(NSString *)propertyName valueSet:(NSSet *)valueSet __attribute__((deprecated));

@end