/*****************************************************************************
 * VLCBookmarksTableViewDataSource.m: MacOS X interface module bookmarking functionality
 *****************************************************************************
 * Copyright (C) 2023 VLC authors and VideoLAN
 *
 * Authors: Claudio Cambra <developer@claudiocambra.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#import "VLCBookmarksTableViewDataSource.h"

#import "VLCBookmark.h"

#import "extensions/NSString+Helpers.h"

#import "library/VLCInputItem.h"
#import "library/VLCLibraryController.h"
#import "library/VLCLibraryDataTypes.h"
#import "library/VLCLibraryImageCache.h"
#import "library/VLCLibraryModel.h"

#import "main/VLCMain.h"

#import "playqueue/VLCPlayerController.h"
#import "playqueue/VLCPlayQueueController.h"

#import "views/VLCTimeFormatter.h"

#import <vlc_media_library.h>
#import <vlc_preparser.h>

NSString * const VLCBookmarksTableViewCellIdentifier = @"VLCBookmarksTableViewCellIdentifier";

NSString * const VLCBookmarksTableViewThumbnailTableColumnIdentifier = @"thumbnail";
NSString * const VLCBookmarksTableViewMediaTableColumnIdentifier = @"media";
NSString * const VLCBookmarksTableViewNameTableColumnIdentifier = @"name";
NSString * const VLCBookmarksTableViewDescriptionTableColumnIdentifier = @"description";
NSString * const VLCBookmarksTableViewTimeTableColumnIdentifier = @"time_offset";

static const NSUInteger kVLCBookmarkThumbnailWidth = 240;
static const NSUInteger kVLCBookmarkThumbnailHeight = 135;
static NSString * const VLCBookmarkThumbnailCacheDirectoryName = @"BookmarkThumbnails";
static NSString * const VLCBookmarkTrackedMediaMRLsDefaultsKey = @"VLCBookmarkTrackedMediaMRLs";
static NSString * const VLCBookmarkStoredBookmarksDefaultsKey = @"VLCStoredBookmarks";
static NSString * const VLCBookmarkStoredMediaIdKey = @"mediaLibraryItemId";
static NSString * const VLCBookmarkStoredMediaTitleKey = @"mediaTitle";
static NSString * const VLCBookmarkStoredMediaMRLKey = @"mediaMRL";
static NSString * const VLCBookmarkStoredTimeKey = @"bookmarkTime";
static NSString * const VLCBookmarkStoredNameKey = @"bookmarkName";
static NSString * const VLCBookmarkStoredDescriptionKey = @"bookmarkDescription";
static NSString * const VLCBookmarksStoreDidChangeDistributedNotification =
    @"org.videolan.vlc.bookmarks.storeDidChange";
static NSString * const VLCBookmarksStoreDidChangeProcessIdentifierKey = @"pid";

static void bookmarksLibraryCallback(void *p_data, const vlc_ml_event_t *p_event)
{
    switch (p_event->i_type)
    {
        case VLC_ML_EVENT_BOOKMARKS_ADDED:
        case VLC_ML_EVENT_BOOKMARKS_DELETED:
        case VLC_ML_EVENT_BOOKMARKS_UPDATED:
        {
            // Need to reload data on main queue
            dispatch_async(dispatch_get_main_queue(), ^{
                VLCBookmarksTableViewDataSource *dataSource = (__bridge VLCBookmarksTableViewDataSource *)p_data;
                [dataSource updateBookmarks];
            });
        }
        break;
        default:
            break;
    }
}

@class VLCBookmarksTableViewDataSource;

@interface VLCBookmarkThumbnailRequest : NSObject

@property (nonatomic, weak) VLCBookmarksTableViewDataSource *dataSource;
@property (nonatomic) int64_t libraryItemId;
@property (nonatomic, copy) NSString *cacheKey;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic) char *filePathCString;

@end

@implementation VLCBookmarkThumbnailRequest

- (void)dealloc
{
    free(_filePathCString);
}

@end

@interface VLCBookmarksTableViewDataSource (BookmarkThumbnailCallback)

- (void)completeThumbnailRequest:(VLCBookmarkThumbnailRequest *)request success:(BOOL)success;

@end

static void bookmarkThumbnailGenerationEnded(vlc_preparser_req *req,
                                             int status,
                                             const bool *result_array,
                                             size_t result_count,
                                             void *data)
{
    VLC_UNUSED(req);

    VLCBookmarkThumbnailRequest * const request = CFBridgingRelease(data);
    const BOOL generationSucceeded = status == VLC_SUCCESS &&
                                     result_array != NULL &&
                                     result_count > 0 &&
                                     result_array[0];

    dispatch_async(dispatch_get_main_queue(), ^{
        [request.dataSource completeThumbnailRequest:request success:generationSucceeded];
    });
}

static const struct vlc_thumbnailer_to_files_cbs bookmarkThumbnailCallbacks = {
    .on_ended = bookmarkThumbnailGenerationEnded,
};

@interface VLCBookmarksTableViewDataSource ()
{
    vlc_medialibrary_t *_mediaLibrary;
    VLCPlayerController *_playerController;
    vlc_ml_event_callback_t *_eventCallback;
    vlc_preparser_t *_thumbnailPreparser;
    VLCMediaLibraryMediaItem *_currentMediaItem;
    NSMutableDictionary<NSString *, NSImage *> *_bookmarkThumbnailCache;
    NSMutableSet<NSString *> *_pendingThumbnailKeys;
    NSString *_thumbnailFileExtension;
    enum vlc_thumbnailer_format _thumbnailFileFormat;
    BOOL _canGenerateBookmarkThumbnails;
}

- (void)resetThumbnailState;
- (nullable NSString *)currentPlaybackMRL;
- (int64_t)mediaIdForMRL:(NSString *)mediaMRL
                isStream:(BOOL)isStream
          createIfNeeded:(BOOL)createIfNeeded;
- (nullable VLCMediaLibraryMediaItem *)mediaItemForLibraryItemId:(int64_t)libraryItemId;
- (NSString *)displayTitleForMediaItem:(nullable VLCMediaLibraryMediaItem *)mediaItem
                           fallbackMRL:(NSString *)mediaMRL;
- (NSString *)displayTitleForMRL:(NSString *)mediaMRL
                 currentInputItem:(nullable VLCInputItem *)currentInputItem;
- (NSArray<NSString *> *)trackedBookmarkMediaMRLs;
- (void)setTrackedBookmarkMediaMRLs:(NSArray<NSString *> *)mediaMRLs;
- (void)trackBookmarkMediaMRL:(nullable NSString *)mediaMRL;
- (void)pruneTrackedBookmarkMediaMRL:(nullable NSString *)mediaMRL mediaId:(int64_t)mediaId;
- (NSArray<NSDictionary<NSString *, id> *> *)storedBookmarkRecords;
- (void)setStoredBookmarkRecords:(NSArray<NSDictionary<NSString *, id> *> *)bookmarkRecords;
- (nullable VLCBookmark *)bookmarkForStoredBookmarkRecord:(NSDictionary<NSString *, id> *)bookmarkRecord;
- (NSDictionary<NSString *, id> *)storedBookmarkRecordForBookmark:(VLCBookmark *)bookmark;
- (NSString *)storeKeyForMediaMRL:(NSString *)mediaMRL bookmarkTime:(int64_t)bookmarkTime;
- (NSString *)storeKeyForBookmark:(VLCBookmark *)bookmark;
- (void)storeBookmark:(VLCBookmark *)bookmark replacingBookmark:(nullable VLCBookmark *)originalBookmark;
- (void)removeStoredBookmark:(VLCBookmark *)bookmark;
- (void)mergeBookmarksIntoStoredBookmarks:(NSArray<VLCBookmark *> *)bookmarks;
- (void)bookmarkStoreDidChange:(NSNotification *)notification;
- (void)postDistributedBookmarkStoreDidChangeNotification;
- (void)updateLibraryItemIdCreatingIfNeeded:(BOOL)createIfNeeded;
- (NSString *)thumbnailCacheKeyForBookmark:(VLCBookmark *)bookmark;
- (NSString *)thumbnailCacheDirectoryPath;
- (NSString *)thumbnailFilePathForBookmark:(VLCBookmark *)bookmark;
- (nullable NSImage *)fallbackThumbnailImageForMediaItem:(nullable VLCMediaLibraryMediaItem *)mediaItem;
- (void)requestThumbnailForBookmark:(VLCBookmark *)bookmark;
- (nullable NSImage *)thumbnailForBookmark:(VLCBookmark *)bookmark;
- (void)removeThumbnailForBookmark:(VLCBookmark *)bookmark;
- (void)completeThumbnailRequest:(VLCBookmarkThumbnailRequest *)request success:(BOOL)success;
@end

@implementation VLCBookmarksTableViewDataSource

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self setup];
    }
    return self;
}

- (instancetype)initWithTableView:(NSTableView *)tableView
{
    self = [super init];
    if (self) {
        [self setup];
        _tableView = tableView;
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];

    if (_eventCallback != NULL && _mediaLibrary != NULL) {
        vlc_ml_event_unregister_callback(_mediaLibrary, _eventCallback);
    }

    if (_thumbnailPreparser != NULL) {
        vlc_preparser_Cancel(_thumbnailPreparser, NULL);
        vlc_preparser_Delete(_thumbnailPreparser);
    }
}

- (void)setup
{
    _playerController = VLCMain.sharedInstance.playQueueController.playerController;
    _mediaLibrary = vlc_ml_instance_get(getIntf());
    _bookmarkThumbnailCache = [NSMutableDictionary dictionary];
    _pendingThumbnailKeys = [NSMutableSet set];

    const struct vlc_preparser_cfg thumbnailCfg = {
        .types = VLC_PREPARSER_TYPE_THUMBNAIL_TO_FILES,
        .max_thumbnailer_threads = 2,
        .timeout = VLC_TICK_FROM_SEC(15),
        .external_process = false,
    };
    _thumbnailPreparser = vlc_preparser_New(VLC_OBJECT(getIntf()), &thumbnailCfg);

    const char *thumbnailFileExtension = NULL;
    _canGenerateBookmarkThumbnails =
        _thumbnailPreparser != NULL &&
        vlc_preparser_GetBestThumbnailerFormat(&_thumbnailFileFormat, &thumbnailFileExtension) == VLC_SUCCESS &&
        thumbnailFileExtension != NULL;
    _thumbnailFileExtension = _canGenerateBookmarkThumbnails ? toNSStr(thumbnailFileExtension) : @"jpg";

    [self updateLibraryItemId];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(currentMediaItemChanged:)
                                               name:VLCPlayerCurrentMediaItemChanged
                                             object:nil];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self
                                                      selector:@selector(bookmarkStoreDidChange:)
                                                          name:VLCBookmarksStoreDidChangeDistributedNotification
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

    if (_mediaLibrary != NULL) {
        _eventCallback = vlc_ml_event_register_callback(_mediaLibrary,
                                                        bookmarksLibraryCallback,
                                                        (__bridge void *)self);
    } else {
        msg_Warn(getIntf(),
                 "Bookmarks: media library unavailable; using local bookmark store");
    }
}

- (void)resetThumbnailState
{
    [_bookmarkThumbnailCache removeAllObjects];
    [_pendingThumbnailKeys removeAllObjects];

    if (_thumbnailPreparser != NULL) {
        vlc_preparser_Cancel(_thumbnailPreparser, NULL);
    }
}

- (NSString *)thumbnailCacheKeyForBookmark:(VLCBookmark *)bookmark
{
    NSString * const mediaIdentifier = bookmark.mediaLibraryItemId > 0 ?
        [NSString stringWithFormat:@"%lld", bookmark.mediaLibraryItemId] :
        [NSString stringWithFormat:@"%lu", (unsigned long)bookmark.mediaMRL.hash];
    return [NSString stringWithFormat:@"%@-%lld",
            mediaIdentifier,
            bookmark.bookmarkTime];
}

- (NSString *)thumbnailCacheDirectoryPath
{
    NSArray<NSString *> * const cacheDirectories =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString * const baseCacheDirectory =
        cacheDirectories.firstObject ?: NSTemporaryDirectory();
    NSString * const bundleIdentifier =
        NSBundle.mainBundle.bundleIdentifier ?: @"org.videolan.vlc";
    NSString * const bookmarkCacheDirectory =
        [[baseCacheDirectory stringByAppendingPathComponent:bundleIdentifier]
         stringByAppendingPathComponent:VLCBookmarkThumbnailCacheDirectoryName];

    [NSFileManager.defaultManager createDirectoryAtPath:bookmarkCacheDirectory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return bookmarkCacheDirectory;
}

- (NSString *)thumbnailFilePathForBookmark:(VLCBookmark *)bookmark
{
    NSString * const filename =
        [[self thumbnailCacheKeyForBookmark:bookmark]
         stringByAppendingPathExtension:_thumbnailFileExtension];
    return [[self thumbnailCacheDirectoryPath] stringByAppendingPathComponent:filename];
}

- (nullable NSImage *)fallbackThumbnailImageForMediaItem:(nullable VLCMediaLibraryMediaItem *)mediaItem
{
    if (mediaItem.smallArtworkGenerated && mediaItem.smallArtworkMRL.length > 0) {
        return [VLCLibraryImageCache thumbnailAtMrl:mediaItem.smallArtworkMRL];
    }

    return [NSImage imageNamed:@"noart.png"];
}

- (void)requestThumbnailForBookmark:(VLCBookmark *)bookmark
{
    if (!_canGenerateBookmarkThumbnails) {
        return;
    }

    NSString * const cacheKey = [self thumbnailCacheKeyForBookmark:bookmark];
    if (_pendingThumbnailKeys.count > 0 && [_pendingThumbnailKeys containsObject:cacheKey]) {
        return;
    }

    NSString * const filePath = [self thumbnailFilePathForBookmark:bookmark];
    VLCBookmarkThumbnailRequest * const request = [[VLCBookmarkThumbnailRequest alloc] init];
    request.dataSource = self;
    request.libraryItemId = bookmark.mediaLibraryItemId;
    request.cacheKey = cacheKey;
    request.filePath = filePath;
    request.filePathCString = strdup(filePath.fileSystemRepresentation);
    if (request.filePathCString == NULL) {
        return;
    }

    VLCInputItem *inputItem = nil;
    VLCMediaLibraryMediaItem * const mediaItem =
        [self mediaItemForLibraryItemId:bookmark.mediaLibraryItemId];
    if (mediaItem != nil) {
        inputItem = mediaItem.inputItem;
    }
    if ((inputItem == nil || inputItem.isStream) && bookmark.mediaMRL.length > 0) {
        NSURL * const mediaURL = [NSURL URLWithString:bookmark.mediaMRL];
        if (mediaURL != nil) {
            inputItem = [VLCInputItem inputItemFromURL:mediaURL];
        }
    }
    if (inputItem == nil || inputItem.isStream) {
        [_pendingThumbnailKeys removeObject:cacheKey];
        return;
    }

    const struct vlc_thumbnailer_arg thumbnailArgs = {
        .seek = {
            .type = VLC_THUMBNAILER_SEEK_TIME,
            .time = VLC_TICK_FROM_MS(bookmark.bookmarkTime),
            .speed = VLC_THUMBNAILER_SEEK_PRECISE,
        },
        .hw_dec = false,
    };
    const struct vlc_thumbnailer_output output = {
        .format = _thumbnailFileFormat,
        .width = (int)kVLCBookmarkThumbnailWidth,
        .height = (int)kVLCBookmarkThumbnailHeight,
        .crop = false,
        .file_path = request.filePathCString,
        .creat_mode = 0644,
    };

    [_pendingThumbnailKeys addObject:cacheKey];

    void * const callbackData = (__bridge_retained void *)request;
    vlc_preparser_req * const req =
        vlc_preparser_GenerateThumbnailToFiles(_thumbnailPreparser,
                                               inputItem.vlcInputItem,
                                               &thumbnailArgs,
                                               &output,
                                               1,
                                               &bookmarkThumbnailCallbacks,
                                               callbackData);

    if (req == NULL) {
        [_pendingThumbnailKeys removeObject:cacheKey];
        (void)CFBridgingRelease(callbackData);
    }
}

- (nullable NSImage *)thumbnailForBookmark:(VLCBookmark *)bookmark
{
    NSString * const cacheKey = [self thumbnailCacheKeyForBookmark:bookmark];
    NSImage * const cachedImage = _bookmarkThumbnailCache[cacheKey];
    if (cachedImage != nil) {
        return cachedImage;
    }

    NSString * const filePath = [self thumbnailFilePathForBookmark:bookmark];
    if ([NSFileManager.defaultManager fileExistsAtPath:filePath]) {
        NSImage * const fileImage = [[NSImage alloc] initWithContentsOfFile:filePath];
        if (fileImage != nil) {
            _bookmarkThumbnailCache[cacheKey] = fileImage;
            return fileImage;
        }
    }

    [self requestThumbnailForBookmark:bookmark];
    return [self fallbackThumbnailImageForMediaItem:[self mediaItemForLibraryItemId:bookmark.mediaLibraryItemId]];
}

- (void)removeThumbnailForBookmark:(VLCBookmark *)bookmark
{
    NSString * const cacheKey = [self thumbnailCacheKeyForBookmark:bookmark];
    [_bookmarkThumbnailCache removeObjectForKey:cacheKey];
    [_pendingThumbnailKeys removeObject:cacheKey];

    NSString * const filePath = [self thumbnailFilePathForBookmark:bookmark];
    if ([NSFileManager.defaultManager fileExistsAtPath:filePath]) {
        [NSFileManager.defaultManager removeItemAtPath:filePath error:nil];
    }
}

- (void)completeThumbnailRequest:(VLCBookmarkThumbnailRequest *)request success:(BOOL)success
{
    [_pendingThumbnailKeys removeObject:request.cacheKey];

    NSImage *thumbnail = nil;
    if (success) {
        thumbnail = [[NSImage alloc] initWithContentsOfFile:request.filePath];
    }

    if (thumbnail == nil) {
        thumbnail = [self fallbackThumbnailImageForMediaItem:[self mediaItemForLibraryItemId:request.libraryItemId]];
    }

    if (thumbnail != nil) {
        _bookmarkThumbnailCache[request.cacheKey] = thumbnail;
        [_tableView reloadData];
    }
}

- (nullable NSString *)currentPlaybackMRL
{
    VLCInputItem * const currentInputItem = _playerController.currentMedia;
    if (currentInputItem == nil) {
        return nil;
    }

    NSString * const mediaMRL = currentInputItem.MRL;
    if (mediaMRL.length == 0) {
        return nil;
    }

    return mediaMRL;
}

- (int64_t)mediaIdForMRL:(NSString *)mediaMRL
                isStream:(BOOL)isStream
          createIfNeeded:(BOOL)createIfNeeded
{
    if (_mediaLibrary == NULL || mediaMRL.length == 0) {
        return -1;
    }

    vlc_ml_media_t *vlcMediaItem = vlc_ml_get_media_by_mrl(_mediaLibrary, mediaMRL.UTF8String);
    if (vlcMediaItem == NULL && createIfNeeded) {
        vlcMediaItem = isStream ?
            vlc_ml_new_stream(_mediaLibrary, mediaMRL.UTF8String) :
            vlc_ml_new_external_media(_mediaLibrary, mediaMRL.UTF8String);
    }
    if (vlcMediaItem == NULL) {
        return -1;
    }

    const int64_t mediaId = vlcMediaItem->i_id;
    vlc_ml_media_release(vlcMediaItem);
    return mediaId;
}

- (nullable VLCMediaLibraryMediaItem *)mediaItemForLibraryItemId:(int64_t)libraryItemId
{
    if (libraryItemId <= 0) {
        return nil;
    }

    return [VLCMediaLibraryMediaItem mediaItemForLibraryID:libraryItemId];
}

- (NSString *)displayTitleForMediaItem:(nullable VLCMediaLibraryMediaItem *)mediaItem
                           fallbackMRL:(NSString *)mediaMRL
{
    if (mediaItem.title.length > 0) {
        return mediaItem.title;
    }
    if (mediaItem.inputItem.name.length > 0) {
        return mediaItem.inputItem.name;
    }

    NSURL * const mediaURL = [NSURL URLWithString:mediaMRL];
    if (mediaURL != nil) {
        NSString * const pathComponent = mediaURL.lastPathComponent.stringByDeletingPathExtension;
        if (pathComponent.length > 0) {
            return pathComponent;
        }
    }

    return mediaMRL;
}

- (NSString *)displayTitleForMRL:(NSString *)mediaMRL
                 currentInputItem:(nullable VLCInputItem *)currentInputItem
{
    if (currentInputItem.MRL.length > 0 &&
        [currentInputItem.MRL isEqualToString:mediaMRL] &&
        currentInputItem.name.length > 0) {
        return currentInputItem.name;
    }

    return [self displayTitleForMediaItem:nil fallbackMRL:mediaMRL];
}

- (NSArray<NSString *> *)trackedBookmarkMediaMRLs
{
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    NSArray<NSString *> * const trackedMRLs =
        [NSUserDefaults.standardUserDefaults stringArrayForKey:VLCBookmarkTrackedMediaMRLsDefaultsKey];
    return trackedMRLs ?: @[];
}

- (void)setTrackedBookmarkMediaMRLs:(NSArray<NSString *> *)mediaMRLs
{
    NSUserDefaults * const defaults = NSUserDefaults.standardUserDefaults;
    if (mediaMRLs.count == 0) {
        [defaults removeObjectForKey:VLCBookmarkTrackedMediaMRLsDefaultsKey];
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        return;
    }

    [defaults setObject:mediaMRLs forKey:VLCBookmarkTrackedMediaMRLsDefaultsKey];
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}

- (void)trackBookmarkMediaMRL:(nullable NSString *)mediaMRL
{
    if (mediaMRL.length == 0) {
        return;
    }

    NSMutableArray<NSString *> * const trackedMRLs = self.trackedBookmarkMediaMRLs.mutableCopy;
    if (![trackedMRLs containsObject:mediaMRL]) {
        [trackedMRLs addObject:mediaMRL];
        [self setTrackedBookmarkMediaMRLs:trackedMRLs];
    }
}

- (void)pruneTrackedBookmarkMediaMRL:(nullable NSString *)mediaMRL mediaId:(int64_t)mediaId
{
    if (_mediaLibrary == NULL || mediaMRL.length == 0 || mediaId <= 0) {
        return;
    }

    vlc_ml_bookmark_list_t * const remainingBookmarks =
        vlc_ml_list_media_bookmarks(_mediaLibrary, nil, mediaId);
    const BOOL hasRemainingBookmarks =
        remainingBookmarks != NULL && remainingBookmarks->i_nb_items > 0;
    if (remainingBookmarks != NULL) {
        vlc_ml_bookmark_list_release(remainingBookmarks);
    }

    if (hasRemainingBookmarks) {
        return;
    }

    NSMutableArray<NSString *> * const trackedMRLs = self.trackedBookmarkMediaMRLs.mutableCopy;
    [trackedMRLs removeObject:mediaMRL];
    [self setTrackedBookmarkMediaMRLs:trackedMRLs];
}

- (NSArray<NSDictionary<NSString *, id> *> *)storedBookmarkRecords
{
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    NSArray * const bookmarkRecords =
        [NSUserDefaults.standardUserDefaults arrayForKey:VLCBookmarkStoredBookmarksDefaultsKey];
    if (![bookmarkRecords isKindOfClass:NSArray.class]) {
        return @[];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> * const validBookmarkRecords = NSMutableArray.array;
    for (id bookmarkRecord in bookmarkRecords) {
        if (![bookmarkRecord isKindOfClass:NSDictionary.class]) {
            continue;
        }

        NSDictionary * const bookmarkRecordDictionary = bookmarkRecord;
        NSString * const mediaMRL = bookmarkRecordDictionary[VLCBookmarkStoredMediaMRLKey];
        NSNumber * const bookmarkTime = bookmarkRecordDictionary[VLCBookmarkStoredTimeKey];
        if (![mediaMRL isKindOfClass:NSString.class] ||
            mediaMRL.length == 0 ||
            ![bookmarkTime isKindOfClass:NSNumber.class]) {
            continue;
        }

        [validBookmarkRecords addObject:bookmarkRecordDictionary];
    }

    return validBookmarkRecords;
}

- (void)setStoredBookmarkRecords:(NSArray<NSDictionary<NSString *, id> *> *)bookmarkRecords
{
    NSUserDefaults * const defaults = NSUserDefaults.standardUserDefaults;
    if (bookmarkRecords.count == 0) {
        [defaults removeObjectForKey:VLCBookmarkStoredBookmarksDefaultsKey];
    } else {
        [defaults setObject:bookmarkRecords forKey:VLCBookmarkStoredBookmarksDefaultsKey];
    }
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}

- (nullable VLCBookmark *)bookmarkForStoredBookmarkRecord:(NSDictionary<NSString *, id> *)bookmarkRecord
{
    NSString * const mediaMRL = bookmarkRecord[VLCBookmarkStoredMediaMRLKey];
    NSNumber * const bookmarkTime = bookmarkRecord[VLCBookmarkStoredTimeKey];
    if (![mediaMRL isKindOfClass:NSString.class] ||
        mediaMRL.length == 0 ||
        ![bookmarkTime isKindOfClass:NSNumber.class]) {
        return nil;
    }

    NSNumber * const mediaLibraryItemId = bookmarkRecord[VLCBookmarkStoredMediaIdKey];
    NSString * const mediaTitle = bookmarkRecord[VLCBookmarkStoredMediaTitleKey];
    NSString * const bookmarkName = bookmarkRecord[VLCBookmarkStoredNameKey];
    NSString * const bookmarkDescription = bookmarkRecord[VLCBookmarkStoredDescriptionKey];

    return [VLCBookmark bookmarkWithMediaLibraryItemId:
                [mediaLibraryItemId isKindOfClass:NSNumber.class] ? mediaLibraryItemId.longLongValue : -1
                                            mediaTitle:[mediaTitle isKindOfClass:NSString.class] ? mediaTitle : @""
                                              mediaMRL:mediaMRL
                                          bookmarkTime:bookmarkTime.longLongValue
                                          bookmarkName:[bookmarkName isKindOfClass:NSString.class] ? bookmarkName : @""
                                   bookmarkDescription:[bookmarkDescription isKindOfClass:NSString.class] ? bookmarkDescription : @""];
}

- (NSDictionary<NSString *, id> *)storedBookmarkRecordForBookmark:(VLCBookmark *)bookmark
{
    NSMutableDictionary<NSString *, id> * const bookmarkRecord = NSMutableDictionary.dictionary;
    bookmarkRecord[VLCBookmarkStoredMediaIdKey] = @(bookmark.mediaLibraryItemId);
    bookmarkRecord[VLCBookmarkStoredMediaMRLKey] = bookmark.mediaMRL ?: @"";
    bookmarkRecord[VLCBookmarkStoredMediaTitleKey] = bookmark.mediaTitle ?: @"";
    bookmarkRecord[VLCBookmarkStoredTimeKey] = @(bookmark.bookmarkTime);
    bookmarkRecord[VLCBookmarkStoredNameKey] = bookmark.bookmarkName ?: @"";
    bookmarkRecord[VLCBookmarkStoredDescriptionKey] = bookmark.bookmarkDescription ?: @"";
    return bookmarkRecord;
}

- (NSString *)storeKeyForMediaMRL:(NSString *)mediaMRL bookmarkTime:(int64_t)bookmarkTime
{
    return [NSString stringWithFormat:@"%@\n%lld", mediaMRL ?: @"", bookmarkTime];
}

- (NSString *)storeKeyForBookmark:(VLCBookmark *)bookmark
{
    return [self storeKeyForMediaMRL:bookmark.mediaMRL bookmarkTime:bookmark.bookmarkTime];
}

- (void)storeBookmark:(VLCBookmark *)bookmark replacingBookmark:(nullable VLCBookmark *)originalBookmark
{
    if (bookmark.mediaMRL.length == 0) {
        return;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> * const bookmarkRecords =
        self.storedBookmarkRecords.mutableCopy;
    NSString * const bookmarkKey = [self storeKeyForBookmark:bookmark];
    NSString * const originalBookmarkKey = originalBookmark != nil ?
        [self storeKeyForBookmark:originalBookmark] :
        bookmarkKey;

    NSIndexSet * const matchingIndexes =
        [bookmarkRecords indexesOfObjectsPassingTest:^BOOL(NSDictionary<NSString *,id> * const storedBookmarkRecord,
                                                           NSUInteger idx,
                                                           BOOL * const stop) {
            VLC_UNUSED(idx);
            VLC_UNUSED(stop);

            VLCBookmark * const storedBookmark =
                [self bookmarkForStoredBookmarkRecord:storedBookmarkRecord];
            if (storedBookmark == nil) {
                return NO;
            }

            NSString * const storedBookmarkKey = [self storeKeyForBookmark:storedBookmark];
            return [storedBookmarkKey isEqualToString:bookmarkKey] ||
                   [storedBookmarkKey isEqualToString:originalBookmarkKey];
        }];
    [bookmarkRecords removeObjectsAtIndexes:matchingIndexes];
    [bookmarkRecords addObject:[self storedBookmarkRecordForBookmark:bookmark]];
    [self setStoredBookmarkRecords:bookmarkRecords];
}

- (void)removeStoredBookmark:(VLCBookmark *)bookmark
{
    if (bookmark.mediaMRL.length == 0) {
        return;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> * const bookmarkRecords =
        self.storedBookmarkRecords.mutableCopy;
    NSString * const bookmarkKey = [self storeKeyForBookmark:bookmark];
    NSIndexSet * const matchingIndexes =
        [bookmarkRecords indexesOfObjectsPassingTest:^BOOL(NSDictionary<NSString *,id> * const storedBookmarkRecord,
                                                           NSUInteger idx,
                                                           BOOL * const stop) {
            VLC_UNUSED(idx);
            VLC_UNUSED(stop);

            VLCBookmark * const storedBookmark =
                [self bookmarkForStoredBookmarkRecord:storedBookmarkRecord];
            return storedBookmark != nil &&
                   [[self storeKeyForBookmark:storedBookmark] isEqualToString:bookmarkKey];
        }];
    [bookmarkRecords removeObjectsAtIndexes:matchingIndexes];
    [self setStoredBookmarkRecords:bookmarkRecords];
}

- (void)mergeBookmarksIntoStoredBookmarks:(NSArray<VLCBookmark *> *)bookmarks
{
    if (bookmarks.count == 0) {
        return;
    }

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> * const storedRecordsByKey =
        NSMutableDictionary.dictionary;
    NSMutableArray<NSString *> * const orderedKeys = NSMutableArray.array;

    for (NSDictionary<NSString *, id> * const storedBookmarkRecord in self.storedBookmarkRecords) {
        VLCBookmark * const storedBookmark =
            [self bookmarkForStoredBookmarkRecord:storedBookmarkRecord];
        if (storedBookmark == nil) {
            continue;
        }

        NSString * const storedBookmarkKey = [self storeKeyForBookmark:storedBookmark];
        if (storedRecordsByKey[storedBookmarkKey] == nil) {
            [orderedKeys addObject:storedBookmarkKey];
        }
        storedRecordsByKey[storedBookmarkKey] = storedBookmarkRecord;
    }

    for (VLCBookmark * const bookmark in bookmarks) {
        if (bookmark.mediaMRL.length == 0) {
            continue;
        }

        NSString * const bookmarkKey = [self storeKeyForBookmark:bookmark];
        if (storedRecordsByKey[bookmarkKey] == nil) {
            [orderedKeys addObject:bookmarkKey];
        }
        storedRecordsByKey[bookmarkKey] = [self storedBookmarkRecordForBookmark:bookmark];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> * const mergedBookmarkRecords = NSMutableArray.array;
    for (NSString * const bookmarkKey in orderedKeys) {
        NSDictionary<NSString *, id> * const bookmarkRecord = storedRecordsByKey[bookmarkKey];
        if (bookmarkRecord != nil) {
            [mergedBookmarkRecords addObject:bookmarkRecord];
        }
    }

    [self setStoredBookmarkRecords:mergedBookmarkRecords];
}

- (void)bookmarkStoreDidChange:(NSNotification *)notification
{
    NSNumber * const sourceProcessId =
        notification.userInfo[VLCBookmarksStoreDidChangeProcessIdentifierKey];
    if (sourceProcessId != nil &&
        sourceProcessId.intValue == NSProcessInfo.processInfo.processIdentifier) {
        return;
    }

    [self updateBookmarks];
}

- (void)postDistributedBookmarkStoreDidChangeNotification
{
    NSDictionary<NSString *, NSNumber *> * const userInfo = @{
        VLCBookmarksStoreDidChangeProcessIdentifierKey:
            @(NSProcessInfo.processInfo.processIdentifier)
    };
    [NSDistributedNotificationCenter.defaultCenter
        postNotificationName:VLCBookmarksStoreDidChangeDistributedNotification
                      object:nil
                    userInfo:userInfo
          deliverImmediately:YES];
}

- (void)updateLibraryItemIdCreatingIfNeeded:(BOOL)createIfNeeded
{
    NSString * const currentMediaMRL = [self currentPlaybackMRL];
    VLCInputItem * const currentInputItem = _playerController.currentMedia;
    if (currentMediaMRL.length == 0 || currentInputItem == nil) {
        _currentMediaItem = nil;
        if (_libraryItemId > 0) {
            [self resetThumbnailState];
        }
        [self setLibraryItemId:-1];
        return;
    }

    const int64_t currentMediaItemId =
        [self mediaIdForMRL:currentMediaMRL
                   isStream:currentInputItem.isStream
             createIfNeeded:createIfNeeded];
    if (currentMediaItemId <= 0) {
        _currentMediaItem = nil;
        if (_libraryItemId > 0) {
            [self resetThumbnailState];
        }
        [self setLibraryItemId:-1];
        return;
    }

    if (currentMediaItemId != _libraryItemId) {
        [self resetThumbnailState];
    }
    _currentMediaItem = [self mediaItemForLibraryItemId:currentMediaItemId];
    [self setLibraryItemId:currentMediaItemId];
}

- (void)updateLibraryItemId
{
    [self updateLibraryItemIdCreatingIfNeeded:NO];
}

- (void)updateBookmarks
{
    NSMutableDictionary<NSString *, VLCBookmark *> * const bookmarksByKey = NSMutableDictionary.dictionary;
    NSMutableArray<NSString *> * const orderedKeys = NSMutableArray.array;

    for (NSDictionary<NSString *, id> * const bookmarkRecord in self.storedBookmarkRecords) {
        VLCBookmark * const bookmark = [self bookmarkForStoredBookmarkRecord:bookmarkRecord];
        if (bookmark == nil) {
            continue;
        }

        NSString * const bookmarkKey = [self storeKeyForBookmark:bookmark];
        if (bookmarksByKey[bookmarkKey] == nil) {
            [orderedKeys addObject:bookmarkKey];
        }
        bookmarksByKey[bookmarkKey] = bookmark;
    }

    NSMutableArray<NSString *> * const trackedMRLs = self.trackedBookmarkMediaMRLs.mutableCopy;
    NSString * const currentMediaMRL = [self currentPlaybackMRL];
    if (currentMediaMRL.length > 0 && ![trackedMRLs containsObject:currentMediaMRL]) {
        [trackedMRLs addObject:currentMediaMRL];
    }

    NSMutableArray<VLCBookmark *> * const libraryBackedBookmarks = NSMutableArray.array;

    if (_mediaLibrary != NULL) {
        for (NSString * const mediaMRL in trackedMRLs) {
            const BOOL isCurrentMedia =
                currentMediaMRL.length > 0 && [currentMediaMRL isEqualToString:mediaMRL];
            const int64_t mediaId = isCurrentMedia ?
                _libraryItemId :
                [self mediaIdForMRL:mediaMRL isStream:NO createIfNeeded:NO];
            if (mediaId <= 0) {
                continue;
            }

            vlc_ml_bookmark_list_t * const vlcBookmarks =
                vlc_ml_list_media_bookmarks(_mediaLibrary, nil, mediaId);
            if (vlcBookmarks == NULL) {
                continue;
            }
            if (vlcBookmarks->i_nb_items == 0) {
                vlc_ml_bookmark_list_release(vlcBookmarks);
                continue;
            }

            VLCMediaLibraryMediaItem * const mediaItem = [self mediaItemForLibraryItemId:mediaId];
            NSString * const mediaTitle =
                [self displayTitleForMediaItem:mediaItem fallbackMRL:mediaMRL];

            for (size_t i = 0; i < vlcBookmarks->i_nb_items; i++) {
                vlc_ml_bookmark_t vlcBookmark = vlcBookmarks->p_items[i];
                VLCBookmark * const bookmark =
                    [VLCBookmark bookmarkWithVlcBookmark:vlcBookmark
                                              mediaTitle:mediaTitle
                                                mediaMRL:mediaMRL];
                NSString * const bookmarkKey = [self storeKeyForBookmark:bookmark];
                if (bookmarksByKey[bookmarkKey] == nil) {
                    [orderedKeys addObject:bookmarkKey];
                }
                bookmarksByKey[bookmarkKey] = bookmark;
                [libraryBackedBookmarks addObject:bookmark];
            }

            vlc_ml_bookmark_list_release(vlcBookmarks);
        }

        [self mergeBookmarksIntoStoredBookmarks:libraryBackedBookmarks];
    }

    NSMutableArray<VLCBookmark *> * const tempBookmarks = NSMutableArray.array;
    for (NSString * const bookmarkKey in orderedKeys) {
        VLCBookmark * const bookmark = bookmarksByKey[bookmarkKey];
        if (bookmark != nil) {
            [tempBookmarks addObject:bookmark];
        }
    }
    _bookmarks = [tempBookmarks copy];

    [_tableView reloadData];
}

- (void)currentMediaItemChanged:(NSNotification * const)notification
{
    [self updateLibraryItemId];
}

- (void)setLibraryItemId:(const int64_t)libraryItemId
{
    if (libraryItemId == _libraryItemId) {
        return;
    }

    _libraryItemId = libraryItemId;
    [self updateBookmarks];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    if (_bookmarks == nil) {
        return 0;
    }

    return _bookmarks.count;
}

- (VLCBookmark *)bookmarkForRow:(NSInteger)row
{
    NSParameterAssert(row >= 0 && (NSUInteger)row < _bookmarks.count);
    return [_bookmarks objectAtIndex:row];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (_bookmarks == nil || _bookmarks.count == 0) {
        return @"";
    }

    VLCBookmark * const bookmark = [self bookmarkForRow:row];
    NSAssert(bookmark != nil, @"Should be a valid bookmark");

    NSString * const identifier = [tableColumn identifier];

    if ([identifier isEqualToString:VLCBookmarksTableViewThumbnailTableColumnIdentifier]) {
        return [self thumbnailForBookmark:bookmark];
    } else if ([identifier isEqualToString:VLCBookmarksTableViewMediaTableColumnIdentifier]) {
        return bookmark.mediaTitle;
    } else if ([identifier isEqualToString:VLCBookmarksTableViewNameTableColumnIdentifier]) {
        return bookmark.bookmarkName;
    } else if ([identifier isEqualToString:VLCBookmarksTableViewDescriptionTableColumnIdentifier]) {
        return bookmark.bookmarkDescription;
    } else if ([identifier isEqualToString:VLCBookmarksTableViewTimeTableColumnIdentifier]) {
        return [NSString stringWithTime:bookmark.bookmarkTime / 1000];
    }

    return @"";
}

- (void)tableView:(NSTableView *)tableView
   setObjectValue:(id)object
   forTableColumn:(NSTableColumn *)tableColumn
              row:(NSInteger)row
{
    VLCBookmark * const bookmark = [self bookmarkForRow:row];
    VLCBookmark * const originalBookmark = [bookmark copy];

    NSString * const columnIdentifier = tableColumn.identifier;

    if ([columnIdentifier isEqualToString:VLCBookmarksTableViewNameTableColumnIdentifier]) {
        NSString * const newName = (NSString *)object;
        bookmark.bookmarkName = newName;
    } else if ([columnIdentifier isEqualToString:VLCBookmarksTableViewDescriptionTableColumnIdentifier]) {
        NSString * const newDescription = (NSString *)object;
        bookmark.bookmarkDescription = newDescription;
    } else if ([columnIdentifier isEqualToString:VLCBookmarksTableViewTimeTableColumnIdentifier]) {
        NSString * const timeString = (NSString *)object;
        VLCTimeFormatter * const formatter = [[VLCTimeFormatter alloc] init];
        NSString *error = nil;
        NSNumber *time = nil;
        [formatter getObjectValue:&time forString:timeString errorDescription:&error];

        if (error == nil) {
            bookmark.bookmarkTime = time.longLongValue;
        } else {
            msg_Err(getIntf(), "Cannot set bookmark time as invalid string format for time was received");
        }
    }

    [self editBookmark:bookmark originalBookmark:originalBookmark];
    [tableView reloadData];
}

- (BOOL)addBookmark:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    const vlc_tick_t currentTime = _playerController.time;
    if (currentTime == VLC_TICK_INVALID || currentTime < VLC_TICK_0) {
        msg_Warn(getIntf(), "Unable to bookmark the current media because the playback time is not available yet");
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VLCBookmarks"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                _NS("Playback has not started yet. Please wait until the media begins playing, then try again.")}];
        }
        return NO;
    }

    NSString * const currentMediaMRL = [self currentPlaybackMRL];
    VLCInputItem * const currentInputItem = _playerController.currentMedia;
    if (currentMediaMRL.length == 0 || currentInputItem == nil) {
        msg_Warn(getIntf(), "Unable to bookmark the current media because no media location is available");
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VLCBookmarks"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                _NS("The currently playing media does not have a location that can be bookmarked.")}];
        }
        return NO;
    }

    const int64_t bookmarkTime = MS_FROM_VLC_TICK(currentTime);
    NSString * const bookmarkDisplayTime = [NSString stringWithTime:bookmarkTime / 1000];
    NSString * const bookmarkName =
        [NSString stringWithFormat:_NS("Bookmark at %@"), bookmarkDisplayTime];
    NSString * const mediaTitle = [self displayTitleForMRL:currentMediaMRL
                                          currentInputItem:currentInputItem];

    if (_mediaLibrary != NULL) {
        [self updateLibraryItemIdCreatingIfNeeded:YES];
        if (_libraryItemId > 0) {
            if (vlc_ml_media_add_bookmark(_mediaLibrary, _libraryItemId, bookmarkTime) != VLC_SUCCESS) {
                msg_Warn(getIntf(),
                         "Unable to save bookmark in media library for media %lld at time %lld; storing locally",
                         _libraryItemId,
                         bookmarkTime);
            } else if (vlc_ml_media_update_bookmark(_mediaLibrary,
                                                    _libraryItemId,
                                                    bookmarkTime,
                                                    bookmarkName.UTF8String,
                                                    NULL) != VLC_SUCCESS) {
                msg_Warn(getIntf(),
                         "Unable to set metadata for bookmark %lld on media %lld",
                         bookmarkTime,
                         _libraryItemId);
            }
        } else {
            msg_Warn(getIntf(),
                     "Unable to resolve media library entry for bookmark; storing locally");
        }
    }

    VLCBookmark * const bookmark =
        [VLCBookmark bookmarkWithMediaLibraryItemId:_libraryItemId
                                         mediaTitle:mediaTitle
                                           mediaMRL:currentMediaMRL
                                       bookmarkTime:bookmarkTime
                                       bookmarkName:bookmarkName
                                bookmarkDescription:@""];
    [self storeBookmark:bookmark replacingBookmark:nil];
    [self trackBookmarkMediaMRL:currentMediaMRL];
    [self updateBookmarks];
    [self postDistributedBookmarkStoreDidChangeNotification];
    return YES;
}

- (void)editBookmark:(VLCBookmark *)bookmark originalBookmark:(VLCBookmark *)originalBookmark
{
    const int64_t mediaId = originalBookmark.mediaLibraryItemId;

    if (_mediaLibrary != NULL && mediaId > 0) {
        if (originalBookmark.bookmarkTime != bookmark.bookmarkTime) {
            if (vlc_ml_media_add_bookmark(_mediaLibrary, mediaId, bookmark.bookmarkTime) == VLC_SUCCESS) {
                vlc_ml_media_remove_bookmark(_mediaLibrary, mediaId, originalBookmark.bookmarkTime);
                [self removeThumbnailForBookmark:originalBookmark];
            } else {
                msg_Warn(getIntf(),
                         "Unable to update bookmark time in media library for media %lld; storing locally",
                         mediaId);
            }
        }

        vlc_ml_media_update_bookmark(_mediaLibrary,
                                     mediaId,
                                     bookmark.bookmarkTime,
                                     bookmark.bookmarkName.UTF8String,
                                     bookmark.bookmarkDescription.UTF8String);
    }

    [self storeBookmark:bookmark replacingBookmark:originalBookmark];
    [self trackBookmarkMediaMRL:bookmark.mediaMRL];
    [self updateBookmarks];
    [self postDistributedBookmarkStoreDidChangeNotification];
}

- (void)removeBookmarkWithTime:(const int64_t)bookmarkTime
{
    for (VLCBookmark * const bookmark in _bookmarks) {
        const BOOL bookmarkMatchesCurrentMedia =
            bookmark.mediaLibraryItemId == _libraryItemId ||
            [bookmark.mediaMRL isEqualToString:self.currentPlaybackMRL];
        if (bookmark.bookmarkTime == bookmarkTime && bookmarkMatchesCurrentMedia) {
            [self removeBookmark:bookmark];
            break;
        }
    }
}

- (void)removeBookmark:(VLCBookmark *)bookmark
{
    [self removeThumbnailForBookmark:bookmark];
    [self removeStoredBookmark:bookmark];
    if (_mediaLibrary != NULL && bookmark.mediaLibraryItemId > 0) {
        vlc_ml_media_remove_bookmark(_mediaLibrary, bookmark.mediaLibraryItemId, bookmark.bookmarkTime);
    }
    [self pruneTrackedBookmarkMediaMRL:bookmark.mediaMRL mediaId:bookmark.mediaLibraryItemId];
    [self updateBookmarks];
    [self postDistributedBookmarkStoreDidChangeNotification];
}

- (void)clearBookmarks
{
    if (_bookmarks.count == 0) {
        return;
    }

    NSMutableSet<NSNumber *> * const mediaIds = NSMutableSet.set;
    for (VLCBookmark * const bookmark in _bookmarks) {
        [self removeThumbnailForBookmark:bookmark];
        if (bookmark.mediaLibraryItemId > 0) {
            [mediaIds addObject:@(bookmark.mediaLibraryItemId)];
        }
    }
    for (NSNumber * const mediaId in mediaIds) {
        if (_mediaLibrary != NULL) {
            vlc_ml_media_remove_all_bookmarks(_mediaLibrary, mediaId.longLongValue);
        }
    }
    [self setStoredBookmarkRecords:@[]];
    [self setTrackedBookmarkMediaMRLs:@[]];
    [self updateBookmarks];
    [self postDistributedBookmarkStoreDidChangeNotification];
}

@end
