//
//  AppDelegate.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/17/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//
//  Modified by True砖家 since 2024.7.12
//  Copyright © 2024 True砖家 @ Bilibili. All rights reserved.
//

#import "AppDelegate.h"
#import "MainFrameViewController.h"
#import "SceneDelegate.h"
#import "VoidLink-Swift.h"
#import "TemporaryHost.h"
#import "TemporaryApp.h"

#if !TARGET_OS_TV
#import <sqlite3.h>
#import "StreamFrameViewController.h"

#pragma mark - OTA update check

// Builds signed by the home server carry OTAUpdateInfoURL in Info.plist (added at signing time, so
// the secret URL never lands in this public repo). It points at info.json, which has the published
// build number and an itms-services install link. When the app comes to the foreground and the
// server has a newer build, offer to install it. Builds without the key never check.
@interface OTAUpdateChecker : NSObject
+ (void)start;
@end

@implementation OTAUpdateChecker

static NSString* otaSkippedBuild;   // "Later" silences a build until the next cold launch
static BOOL otaChecking;

+ (void)start {
    if ([NSBundle.mainBundle objectForInfoDictionaryKey:@"OTAUpdateInfoURL"] == nil) {
        return;
    }
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* note) { [OTAUpdateChecker check]; }];
}

+ (void)check {
    if (otaChecking) return;
    NSURL* url = [NSURL URLWithString:[NSBundle.mainBundle objectForInfoDictionaryKey:@"OTAUpdateInfoURL"]];
    if (url == nil) return;
    otaChecking = YES;

    NSURLRequest* req = [NSURLRequest requestWithURL:url
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:10];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* resp, NSError* error) {
        NSDictionary* info = nil;
        if (data != nil && error == nil && [(NSHTTPURLResponse*)resp statusCode] == 200) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class]) info = json;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            otaChecking = NO;
            if (info != nil) [OTAUpdateChecker offerIfNewer:info];
        });
    }] resume];
}

+ (void)offerIfNewer:(NSDictionary*)info {
    NSString* serverBuild = [info[@"build"] description];
    NSString* install = info[@"install"];
    NSString* myBuild = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    if (serverBuild.length == 0 || ![install isKindOfClass:NSString.class]) return;
    if (serverBuild.integerValue <= myBuild.integerValue) return;   // "x" (pre-CI builds) counts as 0
    if ([serverBuild isEqualToString:otaSkippedBuild]) return;

    UIViewController* top = [OTAUpdateChecker topViewController];
    if (top == nil || [top isKindOfClass:UIAlertController.class]) return;
    // Never interrupt a stream; the next foreground after it ends will ask.
    for (UIViewController* vc = top; vc != nil; vc = vc.presentingViewController ?: vc.parentViewController) {
        if ([vc isKindOfClass:StreamFrameViewController.class]) return;
    }

    NSString* version = [info[@"version"] description] ?: @"";
    NSString* msg = [NSString stringWithFormat:@"Version %@ (build %@) is ready. You have build %@.\n\nYour paired PCs and settings are kept.",
                     version, serverBuild, myBuild];
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Update available"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:^(UIAlertAction* a) {
        otaSkippedBuild = serverBuild;
    }]];
    UIAlertAction* update = [UIAlertAction actionWithTitle:@"Update" style:UIAlertActionStyleDefault handler:^(UIAlertAction* a) {
        NSURL* installURL = [NSURL URLWithString:install];
        if (installURL != nil) [UIApplication.sharedApplication openURL:installURL options:@{} completionHandler:nil];
    }];
    [alert addAction:update];
    alert.preferredAction = update;
    [top presentViewController:alert animated:YES completion:nil];
}

+ (UIViewController*)topViewController {
    UIWindow* window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow* w in ((UIWindowScene*)scene).windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window == nil) window = ((UIWindowScene*)scene).windows.firstObject;
            if (window != nil) break;
        }
    }
    if (window == nil) window = ((AppDelegate*)UIApplication.sharedApplication.delegate).window;
    UIViewController* vc = window.rootViewController;
    while (vc.presentedViewController != nil && !vc.presentedViewController.isBeingDismissed) {
        vc = vc.presentedViewController;
    }
    return vc;
}

@end

#pragma mark - Database salvage

// The Core Data model ("VoidLink v1.0") is edited in place instead of getting a new model version,
// so after an update Core Data can't find the model the old store was written with, migration
// fails, and the store used to be deleted -- losing paired PCs (server certs, pair state), the
// client unique id and all settings. Instead, the old store is moved aside and its rows are copied
// into the fresh store by matching Core Data's SQLite naming (table Z<ENTITY>, column Z<ATTRIBUTE>,
// to-one relationship column Z<RELATIONSHIP> holding the target's Z_PK). New attributes keep their
// model defaults; removed ones are dropped.

static id SalvageColumnValue(sqlite3_stmt* st, int col, NSAttributeType type) {
    if (sqlite3_column_type(st, col) == SQLITE_NULL) return nil;
    switch (type) {
        case NSInteger16AttributeType:
        case NSInteger32AttributeType:
        case NSInteger64AttributeType:
        case NSBooleanAttributeType:
            return @(sqlite3_column_int64(st, col));
        case NSDoubleAttributeType:
        case NSFloatAttributeType:
            return @(sqlite3_column_double(st, col));
        case NSStringAttributeType: {
            const unsigned char* s = sqlite3_column_text(st, col);
            return s != NULL ? [NSString stringWithUTF8String:(const char*)s] : nil;
        }
        case NSDateAttributeType:
            return [NSDate dateWithTimeIntervalSinceReferenceDate:sqlite3_column_double(st, col)];
        case NSBinaryDataAttributeType: {
            const void* bytes = sqlite3_column_blob(st, col);
            int len = sqlite3_column_bytes(st, col);
            return bytes != NULL ? [NSData dataWithBytes:bytes length:len] : [NSData data];
        }
        default:
            return nil;
    }
}

static NSSet<NSString*>* SalvageTableColumns(sqlite3* db, NSString* table) {
    NSMutableSet* cols = [NSMutableSet set];
    sqlite3_stmt* st = NULL;
    NSString* sql = [NSString stringWithFormat:@"PRAGMA table_info(\"%@\")", table];
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const unsigned char* name = sqlite3_column_text(st, 1);
            if (name != NULL) [cols addObject:[NSString stringWithUTF8String:(const char*)name]];
        }
    }
    sqlite3_finalize(st);
    return cols;
}

static NSString* SalvageColumnName(NSString* property) {
    return [@"Z" stringByAppendingString:property.uppercaseString];
}

static NSArray<NSString*>* SalvageFileSuffixes(void) {
    return @[@"", @"-wal", @"-shm"];
}
#endif

#if TARGET_OS_TV
@interface AppDelegate ()
@property (nonatomic, strong) TemporarySettings *tvOSInitialSettingsSnapshot;
@end
#endif

@implementation AppDelegate

@synthesize managedObjectContext = _managedObjectContext;
@synthesize managedObjectModel = _managedObjectModel;
@synthesize persistentStoreCoordinator = _persistentStoreCoordinator;

static NSOperationQueue* mainQueue;

#if TARGET_OS_TV
static NSString* DB_NAME = @"Moonlight_tvOS.bin";
#else
static NSString* DB_NAME = @"Limelight_iOS.sqlite";
#endif

#pragma mark - UISceneSession lifecycle

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options API_AVAILABLE(ios(13.0), tvos(13.0)){
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
    configuration.delegateClass = SceneDelegate.class;
    return configuration;
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions API_AVAILABLE(ios(13.0), tvos(13.0)){
}


#if !TARGET_OS_TV

- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    DataManager *dataMan = [[DataManager alloc] init];
    Settings *currentSettings = [dataMan retrieveSettings];

    if (currentSettings.unlockDisplayOrientation) {
        return UIInterfaceOrientationMaskAll;
    }

    return PublicUtils.isIPhone
        ? UIInterfaceOrientationMaskLandscape
        : [PublicUtils getCurrentOrientationForWindow:window];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for command tool customization after application launch (works only when user default is nil)
    [CommandManager presetDefaultCommands];
    [GenericUtils installSegmentedControlPreviousSelectionTracking];
    [IAPManager shared];
    [OTAUpdateChecker start];

    // For iOS 12 and below, we need to manually create the window
    if (@available(iOS 13.0, *)) {
        // Scene delegate will handle window creation
    } else {
        self.window = [[UIWindow alloc] initWithFrame:[[PublicUtils currentScreen] bounds]];
        
        NSString *storyboardName;
        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
            storyboardName = @"iPad";
        } else {
            storyboardName = @"iPhone";
        }
        
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:storyboardName bundle:nil];
        UIViewController *initialViewController = [storyboard instantiateInitialViewController];
        
        self.window.rootViewController = initialViewController;
        [self.window makeKeyAndVisible];
    }
    
    return YES;
}


- (void)application:(UIApplication *)application performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL succeeded))completionHandler {
    _pcUuidToLoad = (NSString*)[shortcutItem.userInfo objectForKey:@"UUID"];
    _shortcutCompletionHandler = completionHandler;
}
#endif

#if TARGET_OS_TV
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [CommandManager presetDefaultCommands];
    [GenericUtils installSegmentedControlPreviousSelectionTracking];
    [PublicUtils installTextFieldControllerUserInteractionTracking];
    [IAPManager shared];

    // tvOS mounts the settings view lazily when its reveal menu first opens.
    // Read its Core Data snapshot now so that first presentation is RAM-only.
    DataManager *dataManager = [[DataManager alloc] init];
    self.tvOSInitialSettingsSnapshot = [dataManager getSettings];
    return YES;
}

- (TemporarySettings *)consumeTvOSInitialSettingsSnapshot {
    TemporarySettings *snapshot = self.tvOSInitialSettingsSnapshot;
    self.tvOSInitialSettingsSnapshot = nil;
    return snapshot;
}

- (TemporarySettings *)peekTvOSInitialSettingsSnapshot {
    return self.tvOSInitialSettingsSnapshot;
}

- (void)refreshTvOSInitialSettingsSnapshot:(TemporarySettings *)snapshot {
    if (self.tvOSInitialSettingsSnapshot != nil) {
        self.tvOSInitialSettingsSnapshot = snapshot;
    }
}
#endif

- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Saves changes in the application's managed object context before the application terminates.
    [self saveContext];
}

- (void)saveContext
{
    NSManagedObjectContext *managedObjectContext = [self managedObjectContext];
    if (managedObjectContext != nil) {
        [managedObjectContext performBlock:^{
            if (![managedObjectContext hasChanges]) {
                return;
            }
            NSError *error = nil;
            if (![managedObjectContext save:&error]) {
                Log(LOG_E, @"Critical database error: %@, %@", error, [error userInfo]);
            }
            
#if TARGET_OS_TV
            NSData* dbData = [NSData dataWithContentsOfURL:[[[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject] URLByAppendingPathComponent:DB_NAME]];
            [[NSUserDefaults standardUserDefaults] setObject:dbData forKey:DB_NAME];
#endif
        }];
    }
}

#pragma mark - Core Data stack

// Returns the managed object context for the application.
// If the context doesn't already exist, it is created and bound to the persistent store coordinator for the application.
- (NSManagedObjectContext *)managedObjectContext
{
    if (_managedObjectContext != nil) {
        return _managedObjectContext;
    }
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    if (coordinator != nil) {
        _managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        [_managedObjectContext setPersistentStoreCoordinator:coordinator];
    }
    return _managedObjectContext;
}

// Returns the managed object model for the application.
// If the model doesn't already exist, it is created from the application's model.
- (NSManagedObjectModel *)managedObjectModel
{
    if (_managedObjectModel != nil) {
        return _managedObjectModel;
    }
    _managedObjectModel = [NSManagedObjectModel mergedModelFromBundles:nil];
    return _managedObjectModel;
}

// Returns the persistent store coordinator for the application.
// If the coordinator doesn't already exist, it is created and the application's store added to it.
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (_persistentStoreCoordinator != nil) {
        return _persistentStoreCoordinator;
    }
    
    NSError *error = nil;
    _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             [NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption,
                             [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption, nil];
    NSString* storeType;
    
#if TARGET_OS_TV
    // Use a binary store for tvOS since we will need exclusive access to the file
    // to serialize into NSUserDefaults.
    storeType = NSBinaryStoreType;
#else
    storeType = NSSQLiteStoreType;
#endif
    
    // We must ensure the persistent store is ready to opened
    [self preparePersistentStore];
    
    NSPersistentStore *store =
    [_persistentStoreCoordinator addPersistentStoreWithType:storeType
                                              configuration:nil
                                                        URL:[self getStoreURL]
                                                    options:options
                                                      error:&error];
    
    if (store == nil) {
        Log(LOG_E, @"Critical database error: %@, %@", error, [error userInfo]);

#if !TARGET_OS_TV
        // Keep the old store so its data can be copied into the new one below.
        NSURL* salvageURL = [self moveStoreAsideForSalvage];
#endif

        // Old database is incompatible. Remove both the cached copy
        // and the NSUserDefaults backup on tvOS.
        [self dropDatabase];
        
        // The store file no longer exists now.
        // Retry with the current managed object model.
        // Core Data will create a brand-new empty store automatically.
        error = nil;
        
        store =
        [_persistentStoreCoordinator addPersistentStoreWithType:storeType
                                                  configuration:nil
                                                            URL:[self getStoreURL]
                                                        options:options
                                                          error:&error];
        
        if (store == nil) {
            Log(LOG_E,
                @"Failed to create fresh database: %@, %@",
                error,
                [error userInfo]);
            
            // Never return a coordinator with zero persistent stores.
            _persistentStoreCoordinator = nil;
            return nil;
        }
        
        Log(LOG_I, @"Created fresh database using current Core Data model");

#if !TARGET_OS_TV
        if (salvageURL != nil) {
            [self salvageStoreAtURL:salvageURL intoCoordinator:_persistentStoreCoordinator];
        }
#endif
    }

    return _persistentStoreCoordinator;
}

#if !TARGET_OS_TV
// Renames the store and its WAL/SHM files to <store>.salvage*, so the fresh store starts clean
// (a stale -wal next to a new store would corrupt it) and the old rows stay readable.
- (NSURL*)moveStoreAsideForSalvage
{
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* storePath = [self getStoreURL].path;
    NSString* salvagePath = [storePath stringByAppendingString:@".salvage"];
    if (![fm fileExistsAtPath:storePath]) {
        return nil;
    }
    for (NSString* suffix in SalvageFileSuffixes()) {
        NSString* from = [storePath stringByAppendingString:suffix];
        NSString* to = [salvagePath stringByAppendingString:suffix];
        [fm removeItemAtPath:to error:nil];
        if ([fm fileExistsAtPath:from]) {
            NSError* err = nil;
            if (![fm moveItemAtPath:from toPath:to error:&err]) {
                Log(LOG_E, @"Couldn't move %@ aside for salvage: %@", from.lastPathComponent, err);
                return nil;
            }
        }
    }
    return [NSURL fileURLWithPath:salvagePath];
}

- (void)salvageStoreAtURL:(NSURL*)url intoCoordinator:(NSPersistentStoreCoordinator*)coordinator
{
    sqlite3* db = NULL;
    // Read-write so SQLite can replay the old WAL file.
    if (sqlite3_open_v2(url.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        Log(LOG_E, @"Database salvage: can't open old store: %s", db ? sqlite3_errmsg(db) : "?");
        sqlite3_close(db);
        return;
    }

    NSManagedObjectContext* ctx = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    ctx.persistentStoreCoordinator = coordinator;
    __block BOOL saved = NO;
    __block NSUInteger restored = 0;

    [ctx performBlockAndWait:^{
        // entity name -> (old Z_PK -> new object), to rewire to-one relationships afterwards
        NSMutableDictionary<NSString*, NSMutableDictionary<NSNumber*, NSManagedObject*>*>* byEntity = [NSMutableDictionary dictionary];
        NSMutableArray<NSArray*>* links = [NSMutableArray array];   // @[object, relationship name, destination entity, old pk]

        for (NSEntityDescription* entity in coordinator.managedObjectModel.entities) {
            if (entity.isAbstract || entity.superentity != nil) continue;
            NSString* table = SalvageColumnName(entity.name);
            NSSet<NSString*>* cols = SalvageTableColumns(db, table);
            if (![cols containsObject:@"Z_PK"]) continue;

            NSMutableArray<NSAttributeDescription*>* attrs = [NSMutableArray array];
            for (NSAttributeDescription* a in entity.attributesByName.allValues) {
                if ([cols containsObject:SalvageColumnName(a.name)]) [attrs addObject:a];
            }
            NSMutableArray<NSRelationshipDescription*>* rels = [NSMutableArray array];
            for (NSRelationshipDescription* r in entity.relationshipsByName.allValues) {
                if (!r.isToMany && [cols containsObject:SalvageColumnName(r.name)]) [rels addObject:r];
            }

            NSMutableString* sql = [NSMutableString stringWithString:@"SELECT Z_PK"];
            for (NSAttributeDescription* a in attrs) [sql appendFormat:@", \"%@\"", SalvageColumnName(a.name)];
            for (NSRelationshipDescription* r in rels) [sql appendFormat:@", \"%@\"", SalvageColumnName(r.name)];
            [sql appendFormat:@" FROM \"%@\"", table];

            sqlite3_stmt* st = NULL;
            if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) {
                Log(LOG_W, @"Database salvage: skipping %@: %s", entity.name, sqlite3_errmsg(db));
                sqlite3_finalize(st);
                continue;
            }
            NSMutableDictionary<NSNumber*, NSManagedObject*>* map = [NSMutableDictionary dictionary];
            byEntity[entity.name] = map;
            while (sqlite3_step(st) == SQLITE_ROW) {
                NSManagedObject* obj = [NSEntityDescription insertNewObjectForEntityForName:entity.name inManagedObjectContext:ctx];
                int col = 1;
                for (NSAttributeDescription* a in attrs) {
                    id value = SalvageColumnValue(st, col++, a.attributeType);
                    if (value != nil) [obj setValue:value forKey:a.name];
                }
                for (NSRelationshipDescription* r in rels) {
                    if (sqlite3_column_type(st, col) != SQLITE_NULL) {
                        [links addObject:@[obj, r.name, r.destinationEntity.name, @(sqlite3_column_int64(st, col))]];
                    }
                    col++;
                }
                map[@(sqlite3_column_int64(st, 0))] = obj;
            }
            sqlite3_finalize(st);
        }

        for (NSArray* link in links) {
            NSManagedObject* dest = byEntity[link[2]][link[3]];
            if (dest != nil) [link[0] setValue:dest forKey:link[1]];
        }

        // Drop rows whose required to-one relationship couldn't be restored (e.g. an app whose host
        // is gone); they would fail validation and sink the whole save. Apps are re-fetched anyway.
        for (NSDictionary<NSNumber*, NSManagedObject*>* map in byEntity.allValues) {
            for (NSManagedObject* obj in map.allValues) {
                for (NSRelationshipDescription* r in obj.entity.relationshipsByName.allValues) {
                    if (!r.isToMany && !r.isOptional && [obj valueForKey:r.name] == nil) {
                        [ctx deleteObject:obj];
                        break;
                    }
                }
            }
        }

        restored = ctx.insertedObjects.count;
        NSError* err = nil;
        saved = [ctx save:&err];
        if (!saved) {
            Log(LOG_E, @"Database salvage: save failed, starting empty: %@", err);
            [ctx rollback];
        }
    }];
    sqlite3_close(db);

    if (saved) {
        Log(LOG_I, @"Database salvage: restored %lu objects from the previous database", (unsigned long)restored);
        for (NSString* suffix in SalvageFileSuffixes()) {
            [NSFileManager.defaultManager removeItemAtPath:[url.path stringByAppendingString:suffix] error:nil];
        }
    }
    // On failure the .salvage files stay, so nothing is lost for good; the next failed migration
    // overwrites them.
}
#endif

#pragma mark - Application's Documents directory

// Returns the URL to the application's Documents directory.
- (NSURL *)applicationDocumentsDirectory
{
    return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
}

- (void) dropDatabase
{
    // Delete the file on disk
    [[NSFileManager defaultManager] removeItemAtURL:[self getStoreURL] error:nil];
    
#if TARGET_OS_TV
    // Also delete the copy in the NSUserDefaults on tvOS
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:DB_NAME];
#endif
}

- (void) preparePersistentStore
{
#if TARGET_OS_TV
    // On tvOS, we may need to inflate the DB from NSUserDefaults
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheDirectory = [paths objectAtIndex:0];
    NSString *dbPath = [cacheDirectory stringByAppendingPathComponent:DB_NAME];
    
    // Always prefer the on disk version
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) {
        // If that is unavailable, inflate it from NSUserDefaults
        NSData* data = [[NSUserDefaults standardUserDefaults] dataForKey:DB_NAME];
        if (data != nil) {
            Log(LOG_I, @"Inflating database from NSUserDefaults");
            [data writeToFile:dbPath atomically:YES];
        }
        else {
            Log(LOG_I, @"No database on disk or in NSUserDefaults");
        }
    }
    else {
        Log(LOG_I, @"Using cached database");
    }
#endif
}

- (NSURL*) getStoreURL {
#if TARGET_OS_TV
    // We use the cache folder to store our database on tvOS
    return [[[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject] URLByAppendingPathComponent:DB_NAME];
#else
    return [[self applicationDocumentsDirectory] URLByAppendingPathComponent:DB_NAME];
#endif
}

@end
