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


extern NSString *BCCDataStoreControllerWillClearDatabaseNotification;
extern NSString *BCCDataStoreControllerDidClearDatabaseNotification;

extern NSString *BCCDataStoreControllerWillClearIncompatibleDatabaseNotification;
extern NSString *BCCDataStoreControllerDidClearIncompatibleDatabaseNotification;

typedef void (^BCCDataStoreControllerWorkBlock)(BCCDataStoreController *dataStoreController, NSManagedObjectContext *context);
typedef void (^BCCDataStoreControllerPostCreateBlock)(NSManagedObject *createdObject, NSDictionary *dictionary, NSManagedObjectContext *context);


@interface BCCDataStoreController : NSObject {
    
}

@property (strong, nonatomic) NSString *managedObjectModelPath;

@property (strong, nonatomic, readonly) NSString *identifier;
@property (strong, nonatomic, readonly) NSString *rootDirectory;

@property (strong, nonatomic, readonly) NSManagedObjectModel *managedObjectModel;

@property (strong, nonatomic, readonly) NSManagedObjectContext *mainContext;
@property (strong, nonatomic, readonly) NSManagedObjectContext *backgroundContext;

// Class Methods
+ (NSString *)defaultRootDirectory;

// Initialization
- (id)initWithIdentifier:(NSString *)identifier rootDirectory:(NSString *)rootDirectory;
- (id)initWithIdentifier:(NSString *)identifier rootDirectory:(NSString *)rootDirectory modelPath:(NSString *)modelPath;

// Persistent Store State
- (void)reset;
- (void)deletePersistentStore;

// Managed Object Contexts
- (NSManagedObjectContext *)newManagedObjectContextWithConcurrencyType:(NSManagedObjectContextConcurrencyType)concurrencyType;
- (NSManagedObjectContext *)currentContext;

// Saving
- (void)saveCurrentContext;
- (void)saveMainContext;
- (void)saveBackgroundContext;

// Work Queueing
- (void)performBlockOnMainContext:(BCCDataStoreControllerWorkBlock)block;
- (void)performBlockOnMainContextAndWait:(BCCDataStoreControllerWorkBlock)block;
- (void)performBlockOnMainContext:(BCCDataStoreControllerWorkBlock)block afterDelay:(NSTimeInterval)delay;

- (void)performBlockOnBackgroundContext:(BCCDataStoreControllerWorkBlock)block;
- (void)performBlockOnBackgroundContextAndWait:(BCCDataStoreControllerWorkBlock)block;
- (void)performBlockOnBackgroundContext:(BCCDataStoreControllerWorkBlock)block afterDelay:(NSTimeInterval)delay;

- (void)performBlockOnThreadContext:(BCCDataStoreControllerWorkBlock)block;
- (void)performBlockOnThreadContextAndWait:(BCCDataStoreControllerWorkBlock)block;

// Worker Context Memory Cache
- (void)setCacheObject:(NSManagedObject *)cacheObject forContext:(NSManagedObjectContext *)context entityName:(NSString *)entityName identifier:(NSString *)identifier;
- (void)removeCacheObjectForEntityNameForContext:(NSManagedObjectContext *)context entityName:(NSString *)entityName identifier:(NSString *)identifier;
- (NSManagedObject *)cacheObjectForContext:(NSManagedObjectContext *)context entityName:(NSString *)entityName identifier:(NSString *)identifier;

// Entity Creation/Updates
- (NSManagedObject *)createAndInsertObjectWithEntityName:(NSString *)entityName;
- (NSManagedObject *)createAndInsertObjectWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue;

- (NSManagedObject *)findOrCreateObjectWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue;

// Entity Mass Creation
- (NSArray *)createObjectsOfEntityType:(NSString *)entityName fromDictionaryArray:(NSArray *)dictionaryArray findExisting:(BOOL)findExisting dictionaryIdentityProperty:(NSString *)dictionaryIdentityPropertyName modelIdentityProperty:(NSString *)modelIdentityPropertyName postCreateBlock:(BCCDataStoreControllerPostCreateBlock)postCreateBlock;

// Entity Deletion
- (void)deleteObjectsWithEntityName:(NSString *)entityName;
- (void)deleteObjectsWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName identityValue:(id)identityValue;
- (void)deleteObjectsWithEntityName:(NSString *)entityName identityProperty:(NSString *)identityPropertyName valueList:(NSArray *)valueList;

// Fetching By Entity
- (NSArray *)objectsForEntityWithName:(NSString *)entityName;
- (NSArray *)objectsForEntityWithName:(NSString *)entityName filteredByProperty:(NSString *)propertyName valueSet:(NSSet *)valueSet;

- (NSManagedObject *)performSingleResultFetchOfEntityWithName:(NSString *)entityName byProperty:(NSString *)propertyName value:(id)propertyValue error:(NSError **)error;

- (NSArray *)performFetchOfEntityWithName:(NSString *)entityName byProperty:(NSString *)propertyName value:(id)propertyValue sortDescriptors:(NSArray *)sortDescriptors error:(NSError **)error;
- (NSArray *)performFetchOfEntityWithName:(NSString *)entityName byProperty:(NSString *)propertyName valueList:(NSArray *)valueList sortDescriptors:(NSArray *)sortDescriptors error:(NSError **)error;

// Fetching Using Templates
- (NSArray *)performFetchRequestWithTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary sortDescriptors:(NSArray *)sortDescriptors error:(NSError **)error;
- (NSManagedObject *)performSingleResultFetchRequestWithTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary error:(NSError **)error;

// Creating Fetch Requests
- (NSFetchRequest *)fetchRequestForEntityName:(NSString *)entityName sortDescriptors:(NSArray *)sortDescriptors;
- (NSFetchRequest *)fetchRequestForEntityName:(NSString *)entityName byProperty:(NSString *)propertyName value:(id)value sortDescriptors:(NSArray *)sortDescriptors;
- (NSFetchRequest *)fetchRequestForTemplateName:(NSString *)templateName substitutionDictionary:(NSDictionary *)substitutionDictionary sortDescriptors:(NSArray *)sortDescriptors;

// Executing Fetch Requests
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
