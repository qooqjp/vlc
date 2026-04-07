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
- (NSArray<NSString *> *)trackedBookmarkMediaMRLs;
- (void)setTrackedBookmarkMediaMRLs:(NSArray<NSString *> *)mediaMRLs;
- (void)trackBookmarkMediaMRL:(nullable NSString *)mediaMRL;
- (void)pruneTrackedBookmarkMediaMRL:(nullable NSString *)mediaMRL mediaId:(int64_t)mediaId;
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

    if (_eventCallback != NULL) {
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

    _eventCallback = vlc_ml_event_register_callback(_mediaLibrary,
                                                    bookmarksLibraryCallback,
                                                    (__bridge void *)self);
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
    return [NSString stringWithFormat:@"%lld-%lld",
            bookmark.mediaLibraryItemId,
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

- (NSArray<NSString *> *)trackedBookmarkMediaMRLs
{
    NSArray<NSString *> * const trackedMRLs =
        [NSUserDefaults.standardUserDefaults stringArrayForKey:VLCBookmarkTrackedMediaMRLsDefaultsKey];
    return trackedMRLs ?: @[];
}

- (void)setTrackedBookmarkMediaMRLs:(NSArray<NSString *> *)mediaMRLs
{
    NSUserDefaults * const defaults = NSUserDefaults.standardUserDefaults;
    if (mediaMRLs.count == 0) {
        [defaults removeObjectForKey:VLCBookmarkTrackedMediaMRLsDefaultsKey];
        return;
    }

    [defaults setObject:mediaMRLs forKey:VLCBookmarkTrackedMediaMRLsDefaultsKey];
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
    if (mediaMRL.length == 0 || mediaId <= 0) {
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
    if (_mediaLibrary == NULL) {
        _bookmarks = [NSArray array];
        [_tableView reloadData];
        return;
    }

    NSMutableArray<NSString *> * const trackedMRLs = self.trackedBookmarkMediaMRLs.mutableCopy;
    NSString * const currentMediaMRL = [self currentPlaybackMRL];
    if (currentMediaMRL.length > 0 && ![trackedMRLs containsObject:currentMediaMRL]) {
        [trackedMRLs addObject:currentMediaMRL];
    }

    NSMutableArray<NSString *> * const validTrackedMRLs = [NSMutableArray array];
    NSMutableArray<VLCBookmark *> * const tempBookmarks = NSMutableArray.array;

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

        [validTrackedMRLs addObject:mediaMRL];

        VLCMediaLibraryMediaItem * const mediaItem = [self mediaItemForLibraryItemId:mediaId];
        NSString * const mediaTitle =
            [self displayTitleForMediaItem:mediaItem fallbackMRL:mediaMRL];

        for (size_t i = 0; i < vlcBookmarks->i_nb_items; i++) {
            vlc_ml_bookmark_t vlcBookmark = vlcBookmarks->p_items[i];
            VLCBookmark * const bookmark =
                [VLCBookmark bookmarkWithVlcBookmark:vlcBookmark
                                          mediaTitle:mediaTitle
                                            mediaMRL:mediaMRL];
            [tempBookmarks addObject:bookmark];
        }

        vlc_ml_bookmark_list_release(vlcBookmarks);
    }

    [self setTrackedBookmarkMediaMRLs:validTrackedMRLs];
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

- (void)addBookmark
{
    const vlc_tick_t currentTime = _playerController.time;
    if (currentTime == VLC_TICK_INVALID || currentTime < VLC_TICK_0) {
        msg_Warn(getIntf(), "Unable to bookmark the current media because the playback time is not available yet");
        return;
    }

    [self updateLibraryItemIdCreatingIfNeeded:YES];

    if (_libraryItemId <= 0) {
        msg_Warn(getIntf(), "Unable to bookmark the current media because no media library entry could be resolved");
        return;
    }

    const int64_t bookmarkTime = MS_FROM_VLC_TICK(currentTime);
    if (vlc_ml_media_add_bookmark(_mediaLibrary, _libraryItemId, bookmarkTime) != VLC_SUCCESS) {
        msg_Warn(getIntf(), "Unable to bookmark media %lld at time %lld", _libraryItemId, bookmarkTime);
        return;
    }

    NSString * const currentMediaMRL = [self currentPlaybackMRL];
    NSString * const bookmarkDisplayTime = [NSString stringWithTime:bookmarkTime / 1000];
    NSString * const bookmarkName =
        [NSString stringWithFormat:_NS("Bookmark at %@"), bookmarkDisplayTime];
    if (vlc_ml_media_update_bookmark(_mediaLibrary,
                                     _libraryItemId,
                                     bookmarkTime,
                                     bookmarkName.UTF8String,
                                     NULL) != VLC_SUCCESS) {
        msg_Warn(getIntf(), "Unable to set metadata for bookmark %lld on media %lld", bookmarkTime, _libraryItemId);
    }

    [self trackBookmarkMediaMRL:currentMediaMRL];
    [self updateBookmarks];
}

- (void)editBookmark:(VLCBookmark *)bookmark originalBookmark:(VLCBookmark *)originalBookmark
{
    const int64_t mediaId = originalBookmark.mediaLibraryItemId;
    if (mediaId <= 0) {
        return;
    }

    if (originalBookmark.bookmarkTime != bookmark.bookmarkTime) {
        if (vlc_ml_media_add_bookmark(_mediaLibrary, mediaId, bookmark.bookmarkTime) != VLC_SUCCESS) {
            [self updateBookmarks];
            return;
        }
        vlc_ml_media_remove_bookmark(_mediaLibrary, mediaId, originalBookmark.bookmarkTime);
        [self removeThumbnailForBookmark:originalBookmark];
    }

    vlc_ml_media_update_bookmark(_mediaLibrary,
                                 mediaId,
                                 bookmark.bookmarkTime,
                                 bookmark.bookmarkName.UTF8String,
                                 bookmark.bookmarkDescription.UTF8String);

    [self trackBookmarkMediaMRL:bookmark.mediaMRL];
    [self updateBookmarks];
}

- (void)removeBookmarkWithTime:(const int64_t)bookmarkTime
{
    if (_libraryItemId <= 0) {
        return;
    }

    for (VLCBookmark * const bookmark in _bookmarks) {
        if (bookmark.bookmarkTime == bookmarkTime) {
            [self removeThumbnailForBookmark:bookmark];
            break;
        }
    }

    vlc_ml_media_remove_bookmark(_mediaLibrary, _libraryItemId, bookmarkTime);
    [self updateBookmarks];
}

- (void)removeBookmark:(VLCBookmark *)bookmark
{
    if (bookmark.mediaLibraryItemId <= 0) {
        return;
    }

    [self removeThumbnailForBookmark:bookmark];
    vlc_ml_media_remove_bookmark(_mediaLibrary, bookmark.mediaLibraryItemId, bookmark.bookmarkTime);
    [self pruneTrackedBookmarkMediaMRL:bookmark.mediaMRL mediaId:bookmark.mediaLibraryItemId];
    [self updateBookmarks];
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
        vlc_ml_media_remove_all_bookmarks(_mediaLibrary, mediaId.longLongValue);
    }
    [self setTrackedBookmarkMediaMRLs:@[]];
    [self updateBookmarks];
}

@end
