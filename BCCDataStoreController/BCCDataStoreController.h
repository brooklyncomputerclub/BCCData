//
//  BCCDataStoreController.h
//
//  Created by Buzz Andersen on 3/24/11.
//  Copyright 2013 Brooklyn Computer Club. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class BCCTargetActionQueue;
@class BCCDataStoreController;
@class BCCDataStoreControllerWorkParameters;


extern NSString *BCCDataStoreControllerWillClearDatabaseNotification;
extern NSString *BCCDataStoreControllerDidClearDatabaseNotification;

extern NSString *BCCDataStoreControllerWillClearIncompatibleDatabaseNotification;
extern NSString *BCCDataStoreControllerDidClearIncompatibleDatabaseNotification;

typedef void (^BCCDataStoreControllerWorkBlock)(BCCDataStoreController *dataStoreController, NSManagedObjectContext *managedObjectContext, BCCDataStoreControllerWorkParameters *workParameters);

typedef void (^BCCDataStoreControllerPostCreateBlock)(NSManagedObject *createdObject, NSDictionary *dictionary, NSUInteger idx, NSManagedObjectContext *managedObjectContext);

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
- (void)setCacheObject:(NSManagedObject *)cacheObject forMOC:(NSManagedObjectContext *)managedObjectContext entityName:(NSString *)entityName identifier:(NSString *)identifier groupIdentifier:(NSString *)groupIdentifier;
- (void)removeCacheObjectForMOC:(NSManagedObjectContext *)managedObjectContext entityName:(NSString *)entityName identifier:(NSString *)identifier groupIdentifier:(NSString *)groupIdentifier;
- (NSManagedObject *)cacheObjectForMOC:(NSManagedObjectContext *)managedObjectContext entityName:(NSString *)entityName identifier:(NSString *)identifier groupIdentifier:(NSString *)groupIdentifier;

// Entity Creation/Updates
- (NSManagedObject *)createAndInsertObjectWithEntityName:(NSString *)entityName;
- (NSManagedObject *)createAndInsertObjectWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier;

- (NSManagedObject *)findOrCreateObjectWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier;

// Entity Mass Creation
- (NSArray *)createObjectsOfEntityType:(NSString *)entityName fromDictionaryArray:(NSArray *)dictionaryArray usingContextParameters:(BCCDataStoreControllerWorkParameters *)contextParameters postCreateBlock:(BCCDataStoreControllerPostCreateBlock)postCreateBlock;

- (NSArray *)createObjectsOfEntityType:(NSString *)entityName fromDictionaryArray:(NSArray *)dictionaryArray findExisting:(BOOL)findExisting dictionaryIdentityProperty:(NSString *)dictionaryIdentityPropertyName modelIdentityProperty:(NSString *)modelIdentityPropertyName groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier postCreateBlock:(BCCDataStoreControllerPostCreateBlock)postCreateBlock;

// Entity Deletion
- (void)deleteObjects:(NSArray *)affectedObjects;
- (void)deleteObjectsWithEntityName:(NSString *)entityName;
- (void)deleteObjectsWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier;

//- (void)deleteObjectsWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName valueList:(NSArray *)valueList;

// Query by Entity
- (NSArray *)objectsForEntityWithName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors;
- (NSArray *)objectsForEntityWithName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier;
- (NSArray *)objectsForEntityWithName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors groupPropertyName:(NSString *)groupPropertyName groupIdentifier:(NSString *)groupIdentifier filteredByProperty:(NSString *)propertyName valueSet:(NSSet *)valueSet;

// Fetching
- (NSManagedObject *)performSingleResultFetchOfEntityWithName:(NSString *)entityName usingPropertyList:(NSArray *)propertyList valueList:(NSArray *)valueList error:(NSError **)error;
- (NSArray *)performFetchOfEntityWithName:(NSString *)entityName usingPropertyList:(NSArray *)propertyList valueList:(NSArray *)valueList sortDescriptors:(NSArray *)sortDescriptors error:(NSError **)error;

// Fetching Using Templates
- (NSArray *)performFetchRequestWithTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary sortDescriptors:(NSArray *)sortDescriptors error:(NSError **)error;
- (NSManagedObject *)performSingleResultFetchRequestWithTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary error:(NSError **)error;

// Fetch Request Creation
- (NSFetchRequest *)fetchRequestForEntityName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors;
- (NSFetchRequest *)fetchRequestForEntityName:(NSString *)entityName usingPropertyList:(NSArray *)propertyList valueList:(NSArray *)valueList sortDescriptors:(NSArray *)sortDescriptors;
- (NSFetchRequest *)fetchRequestForTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary sortDescriptors:(NSArray *)sortDescriptors;

// Fetch Request Execution
- (NSManagedObject *)performSingleResultFetchRequest:(NSFetchRequest *)fetchRequest error:(NSError **)error;
- (NSArray *)performFetchRequest:(NSFetchRequest *)fetchRequest error:(NSError **)error;

// Change Observation
- (void)addObserver:(id)observer action:(SEL)action forEntityName:(NSString *)entityName;
- (void)addObserver:(id)observer action:(SEL)action forEntityName:(NSString *)entityName withPredicate:(NSPredicate *)predicate requiredChangedKeys:(NSArray *)changedKeys;

- (BOOL)hasObserver:(id)observer;
- (BOOL)hasObserver:(id)observer forEntityName:(NSString *)entityName;

- (void)removeObserver:(id)observer;
- (void)removeObserver:(id)observer forEntityName:(NSString *)entityName;

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


@interface BCCDataStoreControllerImportParameters : NSObject

@property (nonatomic) BOOL findExisting;
@property (nonatomic) BOOL deleteExisting;

@property (copy) BCCDataStoreControllerWorkBlock postCreateBlock;

@property (strong, nonatomic) NSString *groupPropertyName;
@property (strong, nonatomic) NSString *groupIdentifier;

@property (strong, nonatomic) NSString *modelIdentityPropertyName;
@property (strong, nonatomic) NSString *modelContextIdentifierPropertyName;

@property (strong, nonatomic) NSString *dictionaryIdentityPropertyName;

@end
