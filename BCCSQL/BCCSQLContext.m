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

@end


@interface BCCSQLEntity ()

@property (strong, nonatomic) NSMutableArray<BCCSQLColumn *> *columns;

@property (nonatomic, readonly) NSString *createTableSQL;

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
    
    for (BCCSQLEntity *currentEntity in self.entities) {
        NSString *currentCreateSQL = currentEntity.createTableSQL;
        if (!currentCreateSQL) {
            continue;
        }
        
        char *errString;
        sqlite3_exec(_databaseConnection, [currentCreateSQL UTF8String], NULL, NULL, &errString);
        if (errString) {
            NSLog(@"Error creating table: %s", errString);
        }
    }
}

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

@end


@implementation BCCSQLEntity

- (NSString *)createTableSQL
{
    if (!self.tableName) {
        return nil;
    }
    
    NSMutableString *createString = [[NSMutableString alloc] initWithFormat:@"CREATE TABLE IF NOT EXISTS %@", self.tableName];
    
    for (BCCSQLColumn *currentColumn in self.columns) {
        NSString *columnDefinitionSQL = currentColumn.columnDefinitionSQL;
        if (!columnDefinitionSQL) {
            continue;
        }
        
        [createString appendString:columnDefinitionSQL];
    }
    
    return createString;
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

- (NSString *)columnDefinitionSQL
{
    NSString *columnName = self.name;
    if (!columnName) {
        return nil;
    }

    NSMutableString *createString = [[NSMutableString alloc] init];
    
    [createString appendString:columnName];
    
    NSString *type = self.sqlType;
    if (type) {
        [createString appendString:type];
    }
    
    if (self.nonNull) {
        [createString appendString:@"NOT NULL"];
    }
    
    if (self.unique) {
        [createString appendString:@"UNIQUE"];
    }
    
    return createString;
}

@end
