//
//  BCCSQLContext.m
//  Places
//
//  Created by Laurence Andersen on 4/4/16.
//  Copyright © 2016 Brooklyn Computer Club. All rights reserved.
//

#import "BCCSQLContext.h"
#import "NSString+BCCAdditions.h"
#import "NSFileManager+BCCAdditions.h"
#import <sqlite3.h>


@interface BCCSQLContext ()

@property (strong, nonatomic) NSString *databasePath;

@property (nonatomic) sqlite3 *databaseConnection;

@property (strong, nonatomic) NSMutableDictionary<NSString *, BCCSQLEntity *> *entities;

- (void)createEntityTables;

- (sqlite3_stmt *)prepareSQLStatement:(NSString *)SQLString error:(NSError **)error;
- (id<BCCSQLObject>)nextObjectFromStatement:(sqlite3_stmt *)statement forEntity:(BCCSQLEntity *)entity error:(NSError **)error;

@end


@interface BCCSQLEntity ()

@property (strong, nonatomic) NSMutableArray<BCCSQLColumn *> *columns;

@property (nonatomic, readonly) NSString *createTableSQL;

- (NSPredicate *)primaryKeyPredicateForValue:(id)value;

@end


@interface BCCSQLColumn ()

@property (nonatomic, readonly) NSString *columnDefinitionSQL;

@end


@implementation BCCSQLContext

#pragma mark - Initialization

- (instancetype)initWithDatabasePath:(NSString *)databasePath
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _databasePath = databasePath;
    
    _databaseConnection = NULL;
    
    return self;
}

#pragma mark - Database Configuration

- (void)initializeDatabase
{
    NSString *databasePath = self.databasePath;
    if (!databasePath) {
        return;
    }
    
    NSString *rootDirectory = [databasePath BCC_stringByRemovingLastPathComponent];
    if (!rootDirectory) {
        return;
    }
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:rootDirectory]) {
        [[NSFileManager defaultManager] BCC_recursivelyCreatePath:rootDirectory];
    }
    
    int err = sqlite3_open([databasePath UTF8String], &(_databaseConnection));
    if (err != SQLITE_OK) {
        NSLog(@"Error opening database: %s", sqlite3_errstr(err));
        return;
    }
    
    [self createEntityTables];
}

- (void)createEntityTables
{
    if (self.entities.count < 1 || self.databaseConnection == NULL) {
        return;
    }
    
    [self.entities enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, BCCSQLEntity * _Nonnull currentEntity, BOOL * _Nonnull stop) {
        NSString *currentCreateSQL = currentEntity.createTableSQL;
        if (!currentCreateSQL) {
            return;
        }
        
        char *errString;
        sqlite3_exec(_databaseConnection, [currentCreateSQL UTF8String], NULL, NULL, &errString);
        if (errString) {
            NSLog(@"Error creating table: %s", errString);
        }
    }];
}

#pragma mark - Entities

- (void)registerEntity:(BCCSQLEntity *)entity
{
    if (!_entities) {
        _entities = [[NSMutableDictionary alloc] init];
    }
    
    _entities[entity.name] = entity;
}

- (BCCSQLEntity *)entityForName:(NSString *)entityName
{
    return _entities[entityName];
}

#pragma mark - CRUD

- (id<BCCSQLObject>)createOrUpdateObjectForEntityName:(NSString *)entityName usingDictionary:(NSDictionary *)dictionary
{
    return nil;
}

- (id<BCCSQLObject>)findObjectForEntityName:(NSString *)entityName primaryKeyValue:(id)primaryKeyValue
{
    BCCSQLEntity *entity = [self entityForName:entityName];
    if (!entity) {
        return nil;
    }
    
    NSPredicate *primaryKeyPredicate = [entity primaryKeyPredicateForValue:primaryKeyValue];
    if (!primaryKeyPredicate) {
        return nil;
    }
    
    NSArray *foundObjects = [self findObjectsForEntityName:entityName withPredicate:primaryKeyPredicate];
    return foundObjects.firstObject;
}

- (__kindof NSArray<BCCSQLObject> *)findObjectsForEntityName:(NSString *)entityName withPredicate:(NSPredicate *)predicate
{
    if (!_databaseConnection || !entityName) {
        return nil;
    }
    
    BCCSQLEntity *entity = [self entityForName:entityName];
    if (!entity) {
        return nil;
    }
    
    NSString *tableName = entity.tableName;
    if (!tableName) {
        return nil;
    }
    
    NSInteger columnCount = entity.columns.count;
    NSMutableString *columnsString = [[NSMutableString alloc] init];
    
    [entity.columns enumerateObjectsUsingBlock:^(BCCSQLColumn * _Nonnull currentColumn, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *columnName = currentColumn.name;
        if (!columnName) {
            return;
        }
        
        [columnsString appendString:columnName];
        
        if (idx < (columnCount - 1)) {
            [columnsString appendString:@", "];
        }
    }];

    NSMutableString *selectString = [[NSMutableString alloc] initWithFormat:@"SELECT %@ FROM %@", columnsString, tableName];
    
    if (predicate) {
        [selectString appendFormat:@" WHERE %@", predicate.predicateFormat];
    }
    
    NSMutableArray<BCCSQLObject> *foundObjects = nil;
    id<BCCSQLObject> currentObject = nil;
    
    NSError *error;
    sqlite3_stmt *selectStatement = [self prepareSQLStatement:selectString error:&error];
    if (error != nil) {
        return nil;
    }
    
    foundObjects = [[NSMutableArray<BCCSQLObject> alloc] init];
    while (true) {
        currentObject = [self nextObjectFromStatement:selectStatement forEntity:entity error:NULL];
        if (currentObject) {
            [foundObjects addObject:currentObject];
        } else {
            break;
        }
    }
    
cleanup:
    sqlite3_finalize(selectStatement);
    
    return foundObjects;
}

- (void)deleteObjectForEntityName:(NSString *)entityName primaryKeyValue:(id)primaryKeyValue
{
    BCCSQLEntity *entity = [self entityForName:entityName];
    if (!entity) {
        return;
    }
    
    NSPredicate *primaryKeyPredicate = [entity primaryKeyPredicateForValue:primaryKeyValue];
    if (!primaryKeyPredicate) {
        return;
    }
    
    [self deleteObjectsForEntityName:entityName withPredicate:primaryKeyPredicate];
}

- (void)deleteObjectsForEntityName:(NSString *)entityName withPredicate:(NSPredicate *)predicate
{
    if (!_databaseConnection || !entityName) {
        return;
    }
    
    BCCSQLEntity *entity = [self entityForName:entityName];
    if (!entity) {
        return;
    }
    
    NSString *tableName = entity.tableName;
    if (!tableName) {
        return;
    }
    
    NSMutableString *deleteString = [[NSMutableString alloc] initWithFormat:@"DELETE FROM %@", tableName];
    
    if (predicate) {
        [deleteString appendFormat:@" WHERE %@", predicate.predicateFormat];
    }
    
    NSError *error;
    sqlite3_stmt *deleteStatement = [self prepareSQLStatement:deleteString error:&error];
    if (error != nil) {
        return;
    }

    // TO DO: Break this out into a block-based method?
    int stepResult;
    do {
        stepResult = sqlite3_step(deleteStatement);
    } while (stepResult == SQLITE_ROW);
    
    sqlite3_finalize(deleteStatement);
}

#pragma mark - Prepared Statements

- (sqlite3_stmt *)prepareSQLStatement:(NSString *)SQLString error:(NSError **)error
{
    if (!_databaseConnection || !SQLString) {
        return nil;
    }
    
    sqlite3_stmt *statement;
    int err = sqlite3_prepare_v2(_databaseConnection, [SQLString UTF8String], -1, &(statement), NULL);
    if (err != SQLITE_OK) {
        *error = [NSError errorWithDomain:@"BCCSQLContextSQLErrorDomain" code:err userInfo:nil];
        return nil;
    }
    
    *error = nil;
    return statement;
}

- (id<BCCSQLObject>)nextObjectFromStatement:(sqlite3_stmt *)statement forEntity:(BCCSQLEntity *)entity error:(NSError **)error
{
    if (!statement || !entity) {
        return nil;
    }
    
    int stepResult = sqlite3_step(statement);
    if (stepResult != SQLITE_ROW) {
        return nil;
    }
    
    NSObject<BCCSQLObject> *object = [[(Class)entity.instanceClass alloc] init];
    
    [entity.columns enumerateObjectsUsingBlock:^(BCCSQLColumn * _Nonnull currentColumn, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *keyPath = currentColumn.propertyKeyPath;
        
        id value = nil;
        
        // TO DO: Centralize type coercion logic somewhere?
        if (currentColumn.sqlType == BCCSQLTypeText) {
            const unsigned char *stringValue = sqlite3_column_text(statement, (int)idx);
            
            if (stringValue != NULL) {
                NSUInteger dataLength = sqlite3_column_bytes(statement, (int)idx);
                value = [[NSString alloc] initWithBytes:stringValue length:dataLength encoding:NSUTF8StringEncoding];
            }
        } else if (currentColumn.sqlType == BCCSQLTypeNumeric) {

        } else if (currentColumn.sqlType == BCCSQLTypeInteger) {
            int intValue = sqlite3_column_int(statement, (int)idx);
            value = [NSNumber numberWithInt:intValue];
        } else if (currentColumn.sqlType == BCCSQLTypeReal) {
            
        } else if (currentColumn.sqlType == BCCSQLTypeBlob) {
            
        }
        
        [object setValue:value forKeyPath:keyPath];
    }];
    
    return object;
}

@end


@implementation BCCSQLEntity

- (instancetype)initWithName:(NSString *)name
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _name = name;
    
    return self;
}


- (NSString *)createTableSQL
{
    if (!self.tableName) {
        return nil;
    }
    
    NSMutableString *createString = [[NSMutableString alloc] initWithFormat:@"CREATE TABLE IF NOT EXISTS %@", self.tableName];
    NSMutableString *columnsString = [[NSMutableString alloc] init];
    
    NSInteger columnCount = self.columns.count;
    if (columnCount > 0) {
        [columnsString appendString:@"("];
    }
    
    __block BOOL hadValidColumns = NO;
    
    [self.columns enumerateObjectsUsingBlock:^(BCCSQLColumn * _Nonnull currentColumn, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *columnDefinitionSQL = currentColumn.columnDefinitionSQL;
        if (!columnDefinitionSQL) {
            return;
        }
        
        hadValidColumns = YES;
        [columnsString appendString:columnDefinitionSQL];
        
        if ([currentColumn.name isEqualToString:self.primaryKey]) {
            [columnsString appendString:@" PRIMARY KEY"];
        }
        
        if (idx < (columnCount - 1)) {
            [columnsString appendString:@", "];
        }
    }];
    
    if (hadValidColumns) {
        [columnsString appendString:@")"];
        [createString appendString:columnsString];
    }
    
    return createString;
}

- (NSPredicate *)primaryKeyPredicateForValue:(id)value
{
    NSString *primaryKey = self.primaryKey;
    if (!primaryKey) {
        return nil;
    }
    
    return [NSPredicate predicateWithFormat:@"%K == %@", primaryKey, value];
}

- (void)addColumn:(BCCSQLColumn *)column
{
    if (!column) {
        return;
    }
    
    if (!self.columns) {
        _columns = [[NSMutableArray alloc] init];
    }
    
    [_columns addObject:column];
}

- (BCCSQLColumn *)columnForName:(NSString *)columnName
{
    if (!columnName || self.columns.count < 1) {
        return nil;
    }
    
    NSArray *filteredColumns = [_columns filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%K == %@", @"name", columnName]];
    return filteredColumns.firstObject;
}

@end


@implementation BCCSQLColumn

- (instancetype)initWithName:(NSString *)name
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _name = name;
    
    return self;
}

- (NSString *)columnDefinitionSQL
{
    NSString *columnName = self.name;
    if (!columnName) {
        return nil;
    }

    NSMutableString *createString = [[NSMutableString alloc] init];
    
    [createString appendString:columnName];
    
    NSString *typeString = nil;
    
    switch (self.sqlType) {
        case BCCSQLTypeText:
            typeString = @"TEXT";
            break;
        case BCCSQLTypeNumeric:
            typeString = @"NUMERIC";
            break;
        case BCCSQLTypeInteger:
            typeString = @"INTEGER";
            break;
        case BCCSQLTypeReal:
            typeString = @"REAL";
            break;
        default:
            break;
    }
    
    if (typeString != nil) {
        [createString appendFormat:@" %@", typeString];
    }

    if (self.nonNull) {
        [createString appendString:@" NOT NULL"];
    }
    
    if (self.unique) {
        [createString appendString:@" UNIQUE"];
    }
    
    return createString;
}

@end


@implementation BCCSQLTestModelObject

+ (void)performTest
{
    NSString *dbPath = [NSString stringWithFormat:@"%@/%@", [[NSFileManager defaultManager] BCC_cachePathIncludingAppName], @"test.sqlite"];
    BCCSQLContext *sqlContext = [[BCCSQLContext alloc] initWithDatabasePath:dbPath];
    
    BCCSQLEntity *testEntity = [[BCCSQLEntity alloc] initWithName:@"Record"];
    testEntity.tableName = @"records";
    testEntity.instanceClass = [BCCSQLTestModelObject class];
    
    BCCSQLColumn *testColumn1 = [[BCCSQLColumn alloc] initWithName:@"id"];
    testColumn1.sqlType = BCCSQLTypeInteger;
    testColumn1.propertyKeyPath = @"objectID";
    
    [testEntity addColumn:testColumn1];
    testEntity.primaryKey = testColumn1.name;
    
    BCCSQLColumn *testColumn2 = [[BCCSQLColumn alloc] initWithName:@"name"];
    testColumn2.sqlType = BCCSQLTypeText;
    testColumn2.propertyKeyPath = @"name";
    
    [testEntity addColumn:testColumn2];
    
    [sqlContext registerEntity:testEntity];
    
    [sqlContext initializeDatabase];
    
    BCCSQLTestModelObject *foundObject = [sqlContext findObjectForEntityName:@"Record" primaryKeyValue:@(1)];
    NSLog(@"%@", foundObject);
    
    [sqlContext deleteObjectForEntityName:@"Record" primaryKeyValue:@(1)];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p (objectID: %ld; name: %@)>", NSStringFromClass([self class]), self, (long)self.objectID, self.name];
}

@end
