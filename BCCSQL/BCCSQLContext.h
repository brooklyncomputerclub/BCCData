//
//  BCCSQLContext.h
//  Places
//
//  Created by Laurence Andersen on 4/4/16.
//  Copyright © 2016 Brooklyn Computer Club. All rights reserved.
//

#import <Foundation/Foundation.h>

@class BCCSQLEntity;
@class BCCSQLColumn;


@interface BCCSQLContext : NSObject

@property (nonatomic, readonly) NSString *databasePath;

// Initialization
- (instancetype)initWithDatabasePath:(NSString *)databasePath;

// Database Configuration
- (void)initializeDatabase;
- (void)registerEntity:(BCCSQLEntity *)entity;
- (BCCSQLEntity *)entityForName:(NSString *)entityName;

@end


@interface BCCSQLEntity : NSObject

@property (strong, nonatomic) NSString *name;
@property (strong, nonatomic) NSString *tableName;
@property (strong, nonatomic) NSString *primaryKey;

- (void)addColumn:(BCCSQLColumn *)column;
- (BCCSQLColumn *)columnForName:(NSString *)columnName;

@end


@interface BCCSQLColumn : NSObject

@property (strong, nonatomic) NSString *name;
@property (strong, nonatomic) NSString *sqlType;
@property (nonatomic) BOOL nonNull;
@property (nonatomic) BOOL unique;

@end