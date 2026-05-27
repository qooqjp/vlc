/*****************************************************************************
 * VLCBookmark.m: MacOS X interface module bookmarking functionality
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

#import "VLCBookmark.h"

#import "extensions/NSString+Helpers.h"

@implementation VLCBookmark

+ (instancetype)bookmarkWithVlcBookmark:(vlc_ml_bookmark_t)vlcBookmark
{
    return [self bookmarkWithVlcBookmark:vlcBookmark mediaTitle:@"" mediaMRL:@""];
}

+ (instancetype)bookmarkWithVlcBookmark:(vlc_ml_bookmark_t)vlcBookmark
                             mediaTitle:(NSString *)mediaTitle
                               mediaMRL:(NSString *)mediaMRL
{
    return [self bookmarkWithMediaLibraryItemId:vlcBookmark.i_media_id
                                     mediaTitle:mediaTitle
                                       mediaMRL:mediaMRL
                                   bookmarkTime:vlcBookmark.i_time
                                   bookmarkName:toNSStr(vlcBookmark.psz_name) ?: @""
                            bookmarkDescription:toNSStr(vlcBookmark.psz_description) ?: @""];
}

+ (instancetype)bookmarkWithMediaLibraryItemId:(int64_t)mediaLibraryItemId
                                    mediaTitle:(NSString *)mediaTitle
                                      mediaMRL:(NSString *)mediaMRL
                                  bookmarkTime:(int64_t)bookmarkTime
                                  bookmarkName:(NSString *)bookmarkName
                           bookmarkDescription:(NSString *)bookmarkDescription
{
    VLCBookmark * const bookmark = [[VLCBookmark alloc] init];

    bookmark->_mediaLibraryItemId = mediaLibraryItemId;
    bookmark->_mediaTitle = [mediaTitle copy] ?: @"";
    bookmark->_mediaMRL = [mediaMRL copy] ?: @"";
    bookmark.bookmarkTime = bookmarkTime;
    bookmark.bookmarkName = bookmarkName ?: @"";
    bookmark.bookmarkDescription = bookmarkDescription ?: @"";

    return bookmark;
}

- (nonnull id)copyWithZone:(nullable NSZone *)zone
{
    VLCBookmark * const bookmarkCopy = [[VLCBookmark alloc] init];

    bookmarkCopy->_mediaLibraryItemId = self.mediaLibraryItemId;
    bookmarkCopy->_mediaTitle = self.mediaTitle;
    bookmarkCopy->_mediaMRL = self.mediaMRL;
    bookmarkCopy.bookmarkTime = self.bookmarkTime;
    bookmarkCopy.bookmarkName = self.bookmarkName;
    bookmarkCopy.bookmarkDescription = self.bookmarkDescription;

    return bookmarkCopy;
}

@end
