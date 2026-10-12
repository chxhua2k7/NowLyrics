//
//  NLHistory.h
//  Listening history: SpringBoard writes down each song played, whichever app
//  plays it, those left before they counted as skipped (NLHistorySB.x); the
//  settings pages show it (prefsbundle/NLHistoryPages.h).
//
//  One JSON file per day in the jailbreak's root, named by the local date the
//  play started on (yyyy-MM-dd.json): {"version": 1, "plays": [entry, …]}
//  sorted by start.
//  Covers are small JPEGs in Artwork/, one per cover, shared by its plays.
//  Only SpringBoard adds to the files; the settings page deletes from them and
//  says so (NL_HISTORY_EDITED_NOTIFICATION), so SpringBoard stops writing a
//  play that is gone.
//

#import <Foundation/Foundation.h>
#import "NLShared.h"

#ifdef __cplusplus
extern "C" {
#endif

// Inside the jailbreak's root (NLJBPath), as its other files: on rootless
// /var/jb/var/mobile/Library/NowLyrics/History.
#define NL_HISTORY_DIR      NLJBPath(@"/var/mobile/Library/NowLyrics/History")
#define NL_HISTORY_ART_DIR  [NL_HISTORY_DIR stringByAppendingPathComponent:@"Artwork"]

// SpringBoard wrote a play or deleted old days (the pages showing the history
// load again), and the settings page deleted some or all of it (SpringBoard
// checks the play it is on).
#define NL_HISTORY_WRITTEN_NOTIFICATION @"com.c3x14n.nowlyrics/HistoryWritten"
#define NL_HISTORY_EDITED_NOTIFICATION  @"com.c3x14n.nowlyrics/HistoryEdited"

// Preferences: the switch (off by default), how many days are kept (0: all),
// and whether the pages show skipped plays (on by default).
#define NL_HISTORY_PREF          @"history"
#define NL_HISTORY_DAYS_PREF     @"historyDays"
#define NL_HISTORY_SKIPPED_PREF  @"historySkipped"
static const NSInteger kNLHistoryDefaultDays = 90;

// An entry's keys. Times are Unix seconds; `listened` is the seconds it was
// playing, pauses left out. `key` is NLTrackKey of the title and artist the
// player reported, the one NowLyrics keys lyrics, offsets and sources on.
// `skipped` (YES, else left out): it ended before playing 30 seconds or half
// the song.
#define NL_HP_ID        @"id"
#define NL_HP_START     @"start"
#define NL_HP_END       @"end"
#define NL_HP_LISTENED  @"listened"
#define NL_HP_TITLE     @"title"
#define NL_HP_ARTIST    @"artist"
#define NL_HP_ALBUM     @"album"
#define NL_HP_DURATION  @"duration"
#define NL_HP_APP       @"app"
#define NL_HP_KEY       @"key"
#define NL_HP_ART       @"art"     // the cover's file name in Artwork/
#define NL_HP_SKIPPED   @"skipped"

// The day a moment belongs to, as its file is named: yyyy-MM-dd, local time.
NSString *NLHistoryDayKey(NSDate *date);
NSDate *NLHistoryDayDate(NSString *dayKey);   // that day's midnight; nil for a name that is not a day

// Every day that has a file, newest first.
NSArray<NSString *> *NLHistoryDays(void);
NSString *NLHistoryDayPath(NSString *dayKey);   // that day's file
// A day's plays, oldest first (dictionaries with the NL_HP_* keys); empty when it has none.
NSArray<NSDictionary *> *NLHistoryReadDay(NSString *dayKey);
// A cover's path in Artwork/ by its file name; nil for a name that is not one.
NSString *NLHistoryArtworkPath(NSString *name);

// The rest run on the history's own queue, one change after another, so a
// write from SpringBoard and a delete from the settings page never cross.
// Each change done is announced: SpringBoard's by the written notification,
// the page's by the edited one.

// SpringBoard: one play written into its day, replacing the one with its id.
void NLHistorySavePlay(NSDictionary *entry);
// SpringBoard: a cover saved as `name` in Artwork/ unless it is there,
// shrunk to a small JPEG.
void NLHistorySaveArtwork(NSData *data, NSString *name);
// SpringBoard: days older than `keepDays` deleted (0 keeps them all), and
// covers no play uses any more. Announced as written when days went.
void NLHistoryPrune(NSInteger keepDays);
// SpringBoard: whether the play with this id is in its day's file; on the main queue.
void NLHistoryContainsPlay(NSString *dayKey, NSString *identifier, void (^done)(BOOL found));

// The settings page: plays deleted by id from one day, and everything.
// `done` (may be nil) runs on the main queue once it is written.
void NLHistoryDeletePlays(NSString *dayKey, NSSet<NSString *> *identifiers, dispatch_block_t done);
void NLHistoryDeleteAll(dispatch_block_t done);

#ifdef __cplusplus
}
#endif
