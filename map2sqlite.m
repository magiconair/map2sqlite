//
// map2sqlite.m
//
// Copyright (c) 2009, Frank Schroeder, SharpMind GbR
// Copyright (c) 2008-2009, Route-Me Contributors (RMTileKey function)
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

//
// map2sqlite - import utility for the RMDBTileSource
//
// map2sqlite creates an sqlite database with tiles that is
// compatible with the RMDBTileSource of the route-me project.
// 
// It supports importing of OpenStreetmap and ArcGis compatible 
// directory structures of tiles.
//
//     OpenStreetMap tile structure
// 
//         <zoom>/<col>/<row>.png
//
//     zoom, col, row: decimal values
//
//     ArcGIS tile structure
//
//         L<zoom>/R<row>/C<col>.png
//
//     zoom: decimal value
//     col, row: hexadecimal values
//
// The following tables are created and populated.
//
// table "preferences" - contains the map meta data as name/value pairs
//
//    SQL: create table preferences(name text primary key, value text)
//
//    The preferences table must at least contain the following
//    values for the tile source to function properly.
//
//      * map.minZoom           - minimum supported zoom level
//      * map.maxZoom           - maximum supported zoom level
//      * map.tileSideLength    - tile size in pixels
// 
//    Optionally it can contain the following values
// 
//    Coverage area:
//      * map.coverage.topLeft.latitude
//      * map.coverage.topLeft.longitude
//      * map.coverage.bottomRight.latitude
//      * map.coverage.bottomRight.longitude
//      * map.coverage.center.latitude
//      * map.coverage.center.longitude
//
//    Attribution:
//      * map.shortName
//      * map.shortAttribution
//      * map.longDescription
//      * map.longAttribution
//
// table "tiles" - contains the tile images
//
//    SQL: create table tiles(tilekey integer primary key, image blob)
//
//    The tile images are stored in the "image" column as a blob. 
//    The primary key of the table is the "tilekey" which is computed
//    with the RMTileKey function (found in RMTile.h)
//
//    uint64_t RMTileKey(RMTile tile);
//    

#import <Foundation/Foundation.h>
#import "FMDatabase.h"
#import "FMDatabaseAdditions.h"

#define FMDBQuickCheck(SomeBool)	{ if (!(SomeBool)) { NSLog(@"Failure on line %d", __LINE__); return 123; } }
#define FMDBErrorCheck(db)			{ if ([db hadError]) { NSLog(@"DB error %d on line %d: %@", [db lastErrorCode], __LINE__, [db lastErrorMessage]); } }
#define NSStringFromPoint(p)		([NSString stringWithFormat:@"{x=%1.6f,y=%1.6f}", (p).x, (p).y])
#define NSStringFromSize(s)			([NSString stringWithFormat:@"{w=%1.1f,h=%1.1f}", (s).width, (s).height])
#define NSStringFromRect(r)			([NSString stringWithFormat:@"{x=%1.1f,y=%1.1f,w=%1.1f,h=%1.1f}", (r).origin.x, (r).origin.y, (r).size.width, (r).size.height])

// version of this program
#define kVersion @"2.0"

// mandatory preference keys
#define kMinZoomKey @"map.minZoom"
#define kMaxZoomKey @"map.maxZoom"
#define kTileSideLengthKey @"map.tileSideLength"

// optional preference keys for the coverage area
#define kCoverageTopLeftLatitudeKey @"map.coverage.topLeft.latitude"
#define kCoverageTopLeftLongitudeKey @"map.coverage.topLeft.longitude"
#define kCoverageBottomRightLatitudeKey @"map.coverage.bottomRight.latitude"
#define kCoverageBottomRightLongitudeKey @"map.coverage.bottomRight.longitude"
#define kCoverageCenterLatitudeKey @"map.coverage.center.latitude"
#define kCoverageCenterLongitudeKey @"map.coverage.center.longitude"

// optional preference keys for the attribution
#define kShortNameKey @"map.shortName"
#define kLongDescriptionKey @"map.longDescription"
#define kShortAttributionKey @"map.shortAttribution"
#define kLongAttributionKey @"map.longAttribution"



/* ----------------------------------------------------------------------
 * Helper functions
 */


/*
/// Converts a QuadKey into tile XY coordinates.
/// </summary>
/// <param name="quadKey">QuadKey of the tile.</param>
/// <param name="tileX">Output parameter receiving the tile X coordinate.</param>
/// <param name="tileY">Output parameter receiving the tile Y coordinate.</param>
/// <param name="levelOfDetail">Output parameter receiving the level of detail.</param>
 */
void QuadKeyToTileXY(const char* quadKey, int* tileX, int* tileY, int* levelOfDetail)
{
	*levelOfDetail = strlen(quadKey);
	*tileX = 0;
	*tileY = 0;
	
	for(int i = *levelOfDetail; i > 0; i--)
	{
		int mask = 1 << (i - 1);
		switch (quadKey[*levelOfDetail - i])
		{
			case '0':
				break;
				
			case '1':
				*tileX |= mask;
				break;
				
			case '2':
				*tileY |= mask;
				break;
				
			case '3':
				*tileX |= mask;
				*tileY |= mask;
				break;
				
			default:
				NSLog(@"Invalid QuadKey digit sequence.");
		}
	}
}


/*
 * Calculates the top left coordinate of a tile.
 * (assumes OpenStreetmap tiles)
 */
CGPoint pointForTile(int row, int col, int zoom) {
	float lon = col / pow(2.0, zoom) * 360.0 - 180;	
	float n = M_PI - 2.0 * M_PI * row / pow(2.0, zoom);
	float lat = 180.0 / M_PI * atan(0.5 * (exp(n) - exp(-n)));
	
	return CGPointMake(lon, lat);
}

/*
 * Prints usage information.
 */
void printUsage()
{
	printf("  Reads OSM or VE format tiles into an SQLite database file.\n");
	printf("  Usage: map2sqlite -db <db filename> [-mapdir <map directory>]\n");
}

/*
 * Converts a hexadecimal string into an integer value.
 */
NSInteger scanHexInt(NSString* s) {
	unsigned int value;
	
	NSScanner* scanner = [NSScanner scannerWithString:s];
	[scanner setCharactersToBeSkipped:[NSCharacterSet characterSetWithCharactersInString:@"LRC"]];
	if ([scanner scanHexInt:&value])
	{
		return (NSInteger)value;
	}
	else
	{
		NSLog(@"not a hex int %@", s);
		return -1;
	}
}



/*
 * Creates a unique single key for a map tile.
 *
 * Copyright (c) 2008-2009, Route-Me Contributors
 */
uint64_t RMTileKey(int tileZoom, int tileX, int tileY)
{
	uint64_t zoom = (uint64_t) tileZoom & 0xFFLL; // 8bits, 256 levels
	uint64_t x = (uint64_t) tileX & 0xFFFFFFFLL;  // 28 bits
	uint64_t y = (uint64_t) tileY & 0xFFFFFFFLL;  // 28 bits
	
	uint64_t key = (zoom << 56) | (x << 28) | (y << 0);
	
	return key;
}

/* ----------------------------------------------------------------------
 * Database functions
 */

/*
 * Creates an empty sqlite database
 */
FMDatabase* createDB(NSString* dbFile)
{
	// delete the old db file
	if(dbFile == nil || (dbFile.length < 1))
	{
		return nil;
	}
	
	BOOL isDir;
	if([[NSFileManager defaultManager] fileExistsAtPath:dbFile isDirectory:&isDir] && !isDir)
	{
		[[NSFileManager defaultManager] removeItemAtPath:dbFile error:nil];
	}
	
	FMDatabase* db = [FMDatabase databaseWithPath:dbFile];
	NSLog(@"Creating %@", dbFile);
	if (![db open])
	{
		NSLog(@"Could not create %@.", dbFile);
		return nil;
	}
	
	return db;
}

/*
 * Executes a query with error check and returns the result set.
 */
FMResultSet* executeQuery(FMDatabase* db, NSString* sql, ...) {
	va_list args;
	va_start(args, sql);
	FMResultSet* rs = [db executeQuery:sql arguments:args];
	va_end(args);
	FMDBErrorCheck(db);
	
	return rs;
}

/*
 * Executes an update query with error check.
 */
void executeUpdate(FMDatabase* db, NSString* sql, ...) {
	va_list args;
	va_start(args, sql);
	[db executeUpdate:sql arguments:args];
	va_end(args);
	FMDBErrorCheck(db);
}

/* ----------------------------------------------------------------------
 * Preference functions
 */

void addStringAsPref(FMDatabase* db, NSString* name, NSString* value) {
	executeUpdate(db, @"insert into preferences (name, value) values (?,?)", name, value);
}

void addFloatAsPref(FMDatabase* db, NSString* name, float value) {
	addStringAsPref(db, name, [NSString stringWithFormat:@"%f", value]);
}

void addIntAsPref(FMDatabase* db, NSString* name, int value) {
	addStringAsPref(db, name, [NSString stringWithFormat:@"%d", value]);
}

void createPrefs(FMDatabase* db) {
	executeUpdate(db, @"create table preferences(name text primary key, value text)");
}

/* ----------------------------------------------------------------------
 * Main functions
 */

/*
 * Creates the "tiles" table and imports a given directory structure
 * into the table.
 */
void createMapDB(FMDatabase* db, NSString* mapDir)
{
	NSFileManager* fileManager = [NSFileManager defaultManager];
	
	// import the tiles
	executeUpdate(db, @"create table tiles(tilekey integer primary key, zoom integer, row integer, col integer, image blob)");
	
	// OpenStreetMap tile structure
	// 
	//   <zoom>/<col>/<row>.png
	//
	// zoom, col, row: decimal values
	//
	// ArcGIS tile structure
	//
	//   L<zoom>/R<row>/C<col>.png
	//
	// zoom: decimal value
	// col, row: hexadecimal values
	//
	int minZoom = INT_MAX;
	int maxZoom = INT_MIN;
	NSLog(@"Importing map tiles at %@", mapDir);
	
	NSArray* paths = [fileManager subpathsAtPath:mapDir];
	
	for (NSString* f in paths)
	{
		if ([[[f pathExtension] lowercaseString] isEqualToString:@"png"])
		{
			NSArray* comp = [f componentsSeparatedByString:@"/"];
			int zoom, row, col;
			
			// openstreetmap or ArcGis tiles?
			if ([[comp objectAtIndex:0] characterAtIndex:0] == 'L')
			{
				zoom = [[[comp objectAtIndex:0] substringFromIndex:1] intValue];
				row = scanHexInt([comp objectAtIndex:1]);
				col = scanHexInt([[comp objectAtIndex:2] stringByDeletingPathExtension]);
			}
			else if(comp.count == 1) //
			{
				NSString* tileName = [comp objectAtIndex:0];
				NSRange r = {0, tileName.length - 4};
				tileName = [tileName substringWithRange:r];
				const char* tile = [tileName UTF8String];
				
				QuadKeyToTileXY(tile, &row, &col, &zoom);
			}
			else
			{
				zoom = [[comp objectAtIndex:0] intValue];
				col = [[comp objectAtIndex:1] intValue];
				row = [[[comp objectAtIndex:2] stringByDeletingPathExtension] intValue];
			}
			
			// update min and max zoom
			minZoom = fmin(minZoom, zoom);
			maxZoom = fmax(maxZoom, zoom);
			
			NSData* image = [[NSData alloc] initWithContentsOfFile:[NSString stringWithFormat:@"%@/%@", mapDir, f]];
			if (image)
			{
				executeUpdate(db, @"insert into tiles (tilekey, zoom, row, col, image) values (?, ?, ?, ?, ?)", 
							  [NSNumber numberWithLongLong:RMTileKey(zoom, col, row)],
							  [NSNumber numberWithInt:zoom], 
							  [NSNumber numberWithInt:row], 
							  [NSNumber numberWithInt:col], 
							  image);
				[image release];
			}
			else
			{
				NSLog(@"Could not read %@", f);
			}
		}
	}
	
	// add mandatory map meta data to the preferences table
	addIntAsPref(db, kMinZoomKey, minZoom);
	addIntAsPref(db, kMaxZoomKey, maxZoom);
	addIntAsPref(db, kTileSideLengthKey, 256);
	
	// add coverage area and center
	// print map dimensions per zoom level
	FMResultSet* rs = executeQuery(db, @"select min(row) min_row, min(col) min_col, max(row) max_row, max(col) max_col from tiles where zoom = ?",	[NSNumber numberWithInt:maxZoom]);
	while ([rs next]) {
		int minRow = [rs intForColumn:@"min_row"];
		int minCol = [rs intForColumn:@"min_col"];
		int maxRow = [rs intForColumn:@"max_row"];
		int maxCol = [rs intForColumn:@"max_col"];
		CGPoint topLeft = pointForTile(minRow, minCol, maxZoom);
		CGPoint bottomRight = pointForTile(maxRow + 1, maxCol + 1, maxZoom);
		addFloatAsPref(db, kCoverageTopLeftLatitudeKey, topLeft.y);
		addFloatAsPref(db, kCoverageTopLeftLongitudeKey, topLeft.x);
		addFloatAsPref(db, kCoverageBottomRightLatitudeKey, bottomRight.y);
		addFloatAsPref(db, kCoverageBottomRightLongitudeKey, bottomRight.x);
		
		// this prolly works only for the northern hemisphere
		// I'm just too lazy to do it right for now
		addFloatAsPref(db, kCoverageCenterLatitudeKey, topLeft.y + (bottomRight.y - topLeft.y)/2);
		addFloatAsPref(db, kCoverageCenterLongitudeKey, topLeft.x + (bottomRight.x - topLeft.x)/2);
	}
	[rs close];
	
}

/*
 * Displays some statistics about the tiles in the imported database.
 */
void showMapDBStats(FMDatabase* db, NSString* dbFile, NSString* mapDir) {
	// print some map statistics
	// print some map statistics
	FMResultSet* rs = executeQuery(db, @"select count(*) count, min(zoom) min_zoom, max(zoom) max_zoom from tiles");
	if ([rs next]) {
		int count = [rs intForColumn:@"count"];
		int minZoom = [rs intForColumn:@"min_zoom"];
		int maxZoom = [rs intForColumn:@"max_zoom"];
		
		NSError *error;
		NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:dbFile error:&error];
		unsigned long long fileSize = [[fileAttributes objectForKey:NSFileSize] unsignedLongLongValue];
		
		NSLog(@"\n");
		NSLog(@"Map statistics");
		NSLog(@"--------------");
		NSLog(@"map db:            %@", dbFile);
		NSLog(@"file size:         %qi bytes", fileSize);
		NSLog(@"tile directory:    %@", mapDir);
		NSLog(@"number of tiles:   %d", count);
		NSLog(@"zoom levels:       %d - %d", minZoom, maxZoom);
	}
	[rs close];
	
	// print map dimensions per zoom level
	rs = executeQuery(db, @"select zoom, count(zoom) count, min(row) min_row, min(col) min_col, max(row) max_row, max(col) max_col from tiles group by zoom");
	while ([rs next]) {
		int zoom = [rs intForColumn:@"zoom"];
		int count = [rs intForColumn:@"count"];
		int minRow = [rs intForColumn:@"min_row"];
		int minCol = [rs intForColumn:@"min_col"];
		int maxRow = [rs intForColumn:@"max_row"];
		int maxCol = [rs intForColumn:@"max_col"];
		CGPoint topLeft = pointForTile(minRow, minCol, zoom);
		CGPoint bottomRight = pointForTile(maxRow + 1, maxCol + 1, zoom);
		
		NSLog(@"zoom level %2d:    %6d tiles, (%6d,%6d)x(%6d,%6d), %@x%@",
			  zoom,
			  count,
			  minRow,
			  minCol,
			  maxRow,
			  maxCol,
			  NSStringFromPoint(topLeft),
			  NSStringFromPoint(bottomRight));
	}
	[rs close];
}


/*
 * main method
 */
int main (int argc, const char * argv[])
{
	NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
	NSFileManager* fileManager = [NSFileManager defaultManager];
	char buffer[128];

	// print the version
    printf("map2sqlite %s\n", [kVersion UTF8String]);
	printUsage();
	
	// get the command line args
	NSUserDefaults *args = [NSUserDefaults standardUserDefaults];
	
	// command line args
	NSString* dbFile = [args stringForKey:@"db"];
	NSString* mapDir = [args stringForKey:@"mapdir"];
	
	NSString* currentDir = [fileManager currentDirectoryPath];
	printf("> %s\n", [currentDir UTF8String]);

	// check that the map directory exists
	BOOL isDir;
	
	if(mapDir == nil)
	{
		size_t length;
		printf("Enter map directory > ");
		if (fgets(buffer, sizeof(buffer), stdin) == NULL)
		{
			[pool release];
			return 1;
		}
		
		length = strlen(buffer);
		if (buffer[length - 1] == '\n') // remove the traling '\n' add by fgets
			buffer[length - 1] = '\0';
		mapDir = [NSString stringWithCString:buffer encoding:NSASCIIStringEncoding];
	}
	
	if(![fileManager fileExistsAtPath:mapDir isDirectory:&isDir] || !isDir)
	{
		NSLog(@"Map directory does not exist: %@", mapDir);
		[pool release];
		return 3;
	}

	// check command line args
	if(dbFile == nil)
	{
		size_t length;
		printf("Enter DB file name > ");
		if (fgets(buffer, sizeof(buffer), stdin) == NULL)
			return -1; // error or end of file sent to the terminal
		length = strlen(buffer);
		if (buffer[length - 1] == '\n') // remove the traling '\n' add by fgets
			buffer[length - 1] = '\0';
		
		dbFile = [NSString stringWithCString:buffer encoding:NSASCIIStringEncoding];
	}
	
	if((dbFile == nil) || (dbFile.length < 1))
	{
		dbFile = [mapDir lastPathComponent];
	}
	
	NSString* ext = [dbFile pathExtension];
	
	if((ext == nil) || (ext.length < 1))
	{
		dbFile = [dbFile stringByAppendingString:@".db"];
	}

	// delete any old db
	if([fileManager fileExistsAtPath:dbFile isDirectory:&isDir])
	{
		if(isDir)
		{
			NSLog(@"Error db file name is a directory: %@", dbFile);
			[pool release];
			return 4;
		}
		else
		{
			NSURL *fileURL = [NSURL fileURLWithPath:dbFile];
			[fileManager removeItemAtURL:fileURL error:nil];
		}
	}
	
	// create the db
	FMDatabase* db = createDB(dbFile);
	
	if(db == nil)
	{
		NSLog(@"Error creating database: %@", dbFile);
		[pool release];
		return 3;
	}
	
	// cache the statements as we're using them a lot
	db.shouldCacheStatements = YES;
	
	// create the preferences table
	createPrefs(db);
	
	// import the map
	if (mapDir != nil)
	{
		createMapDB(db, mapDir);
		showMapDBStats(db, dbFile, mapDir);
	}

	// cleanup
	[db close];
    [pool release];
    return 0;
}
