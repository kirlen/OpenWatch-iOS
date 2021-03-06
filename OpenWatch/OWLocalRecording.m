//
//  OWLocalRecording.m
//  OpenWatch
//
//  Created by Christopher Ballinger on 12/3/12.
//  Copyright (c) 2012 OpenWatch FPC. All rights reserved.
//

#import "OWLocalRecording.h"
#import "OWSettingsController.h"
#import "OWCaptureAPIClient.h"
#import "OWLocationController.h"



@implementation OWLocalRecording



- (NSString*) localRecordingPath {
    return [OWLocalRecording pathForUUID:self.uuid];
}

+ (OWLocalRecording*) recording {
    OWLocalMediaObject* recording = [self localMediaObject];
    if (![recording isKindOfClass:[OWLocalRecording class]]) {
        return nil;
    }
    return (OWLocalRecording*)recording;
}

+ (NSString*) mediaDirectoryPath {
    return [self mediaDirectoryPathForMediaType:@"videos"];
}

- (NSString*) localMediaPath {
    NSString *uuidPath = [self localRecordingPath];
    NSString *path = [uuidPath stringByAppendingPathComponent:kHQFileName];
    return path;
}

+ (OWLocalRecording*) recordingWithUUID:(NSString *)uuid {
    OWLocalMediaObject *mediaObject =[OWLocalMediaObject localMediaObjectWithUUID:uuid];
    if (![mediaObject isKindOfClass:[OWLocalRecording class]]) {
        return nil;
    }
    return (OWLocalRecording*)mediaObject;
}

- (void) setUploadState:(OWFileUploadState)uploadState forFileAtURL :(NSURL *)url {
    NSString *path = [url path];
    NSString *fileName = [path lastPathComponent];
    NSManagedObjectContext *context = [NSManagedObjectContext MR_contextForCurrentThread];
    [context processPendingChanges];
    OWLocalRecording *recording = (OWLocalRecording*)[context existingObjectWithID:self.objectID error:nil];

    if ([[path lastPathComponent] isEqualToString:kHQFileName]) {
        recording.hqFileUploadState = @(uploadState);
        [context MR_saveToPersistentStoreAndWait];
        return;
    }
    
    OWRecordingSegment *segment = [OWRecordingSegment MR_findFirstByAttribute:@"filePath" withValue:path];
    if (segment) {
        segment.fileUploadState = uploadState;
    } else {
        segment = [OWRecordingSegment MR_createEntity];
        segment.filePath = path;
        segment.fileUploadState = uploadState;
        segment.recording = self;
        segment.fileName = fileName;
    }
    [context MR_saveToPersistentStoreAndWait];
}

- (OWFileUploadState)uploadStateForFileAtURL:(NSURL*)url {
    NSString *path = [url path];
    
    if ([[path lastPathComponent] isEqualToString:kHQFileName]) {
        return [self.hqFileUploadState unsignedIntegerValue];
    }
    
    OWRecordingSegment *segment = [OWRecordingSegment MR_findFirstByAttribute:@"filePath" withValue:path];
    if (!segment) {
        return OWFileUploadStateUnknown;
    }
    return segment.fileUploadState;
}


- (NSDictionary*) metadataDictionary {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithDictionary:[super metadataDictionary]];
    NSArray *paths = [self pathsForSegments];
    if (paths) {
        [dictionary setObject:paths forKey:kAllFilesKey];
    }
    return dictionary;
}

- (void) checkIntegrity {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *recordingFileNames = [fileManager contentsOfDirectoryAtPath:self.localRecordingPath error:&error];
    if (error) {
        NSLog(@"Error getting contents of recording directory: %@", self.localRecordingPath);
    }
        
    BOOL dataHasChanged = NO;
    
    for (NSString *fileName in recordingFileNames) {
        if ([fileName rangeOfString:@"mp4"].location != NSNotFound) {
            NSString *videoPath = [self.localRecordingPath stringByAppendingPathComponent:fileName];
            NSURL *url = [NSURL URLWithString:videoPath];
            OWFileUploadState state = [self uploadStateForFileAtURL:url];
            if (state == OWFileUploadStateUnknown) {
                NSLog(@"Unrecognized file found (%@): %@", self.localRecordingPath, videoPath);
                [self setUploadState:OWFileUploadStateFailed forFileAtURL:url];
                dataHasChanged = YES;
            }
        }
    }
    if (dataHasChanged) {
        [self saveMetadata];
    }
}


- (void) locationUpdated:(CLLocation *)location {
    if (!self.startLocation) {
        self.startLocation = location;
        [self saveMetadata];
    }
}

- (void) startRecording {
    self.startDate = [NSDate date];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory;
    if (![fileManager fileExistsAtPath:self.localRecordingPath isDirectory:&isDirectory]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:[self pathForSegmentsDirectory] withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"Error creating directory: %@%@", [error localizedDescription], [error userInfo]);
        }
    }
    [self saveMetadata];
    [[OWCaptureAPIClient sharedClient] startedRecording:self.objectID callback:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[OWLocationController sharedInstance] startWithDelegate:self];
    });
}

- (NSString*) pathForSegmentsDirectory {
    return [self.localRecordingPath stringByAppendingPathComponent:kSegmentsDirectory];
}

- (void) stopRecording {
    self.endDate = [NSDate date];
    CLLocation *endLoc = [OWLocationController sharedInstance].currentLocation;
    self.endLocation = endLoc;
    [self saveMetadata];
    [[OWCaptureAPIClient sharedClient] finishedRecording:self.objectID callback:^(BOOL success) {
        [[OWCaptureAPIClient sharedClient] updateMetadataForRecording:self.objectID callback:nil];
    }];
}

- (NSURL*) highQualityURL {
    NSString *movieName = kHQFileName;
    NSString *path = [self.localRecordingPath stringByAppendingPathComponent:movieName];
    NSURL *newMovieURL = [NSURL fileURLWithPath:path];
    return newMovieURL;
}

- (NSArray*) pathsForSegments {
    NSManagedObjectContext *context = [NSManagedObjectContext MR_contextForCurrentThread];
    NSError *error = nil;
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self pathForSegmentsDirectory] error:&error];
    if (error) {
        NSLog(@"Error with segments paths: %@", [error userInfo]);
    }
    for (NSString *fileName in contents) {
        NSString *filePath = [[self pathForSegmentsDirectory] stringByAppendingPathComponent:fileName];
        OWRecordingSegment *segment = [OWRecordingSegment MR_findFirstByAttribute:OWRecordingSegmentAttributes.filePath withValue:filePath inContext:context];
        ;
        if (!segment) {
            NSLog(@"Segment not found! Creating segment for %@", filePath);
            segment = [OWRecordingSegment MR_createEntity];
            segment.filePath = filePath;
            segment.fileName = fileName;
            segment.uploadState = @(OWFileUploadStateFailed);
            segment.recording = self;
        }
    }
    [context MR_saveToPersistentStoreAndWait];
    return contents;
}

- (NSURL*) urlForNextSegmentWithCount:(NSUInteger)count {
    NSString *movieName = [NSString stringWithFormat:@"%d.mp4", count+1];
    NSString *path = [[self pathForSegmentsDirectory] stringByAppendingPathComponent:movieName];
    NSURL *newMovieURL = [NSURL fileURLWithPath:path];
    return newMovieURL;
}

- (NSUInteger) failedFileCount {
    return [[self failedFileSegments] count];
}

- (NSSet*) failedFileSegments {
    NSPredicate *predicate =
    [NSPredicate predicateWithFormat:@"fileUploadState != %d", OWFileUploadStateCompleted];
    NSSet *filteredSet = [self.segments filteredSetUsingPredicate:predicate];
    return filteredSet;
}

- (NSUInteger) completedFileCount {
    NSPredicate *predicate =
    [NSPredicate predicateWithFormat:@"fileUploadState == %d", OWFileUploadStateCompleted];
    NSSet *filteredSet = [self.segments filteredSetUsingPredicate:predicate];
    return [filteredSet count];
}

- (NSUInteger) totalFileCount {
    return [[self pathsForSegments] count];
}

- (BOOL) isHighQualityFileUploaded {
    OWFileUploadState uploadState = [self uploadStateForFileAtURL:[self highQualityURL]];
    return uploadState == OWFileUploadStateCompleted;
}

- (NSArray*) failedFileUploadURLs {
    NSSet *failedFileSegments = [self failedFileSegments];
    NSMutableArray *urls = [NSMutableArray array];
    for (OWRecordingSegment *segment in failedFileSegments) {
        NSString *path = segment.filePath;
        [urls addObject:[NSURL fileURLWithPath:path]];
    }
    if (!self.isHighQualityFileUploaded) {
        [urls addObject:self.highQualityURL];
    }
    return urls;
}


@end
