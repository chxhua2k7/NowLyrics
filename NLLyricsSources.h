//
//  NLLyricsSources.h
//  Picking a song's lyrics source from outside its app, as the Now Playing
//  page does, and the lines around the one being sung: what the Control
//  Center module and the system player (NLSystemPlayerSB.x) share. The page
//  itself reads and writes through its list controllers
//  (NLNowPlayingController.m).
//

#import <Foundation/Foundation.h>
#import "NLLocate.h"

@class NLLyricLine;

#ifdef __cplusplus
extern "C" {
#endif

// The whole domain as cfprefsd has it now (the file can be behind).
NSDictionary *NLReadPrefsNow(void);
// One setting straight into the domain, without the reload notice: the
// settings written from outside the apps are none they reload for (a source
// picked for one song reaches its app beside its nowplaying.plist,
// NLLookUpAgain), and a notice is a settings change to Quit app on change.
void NLWritePrefQuietly(NSString *key, id value);

// The sources a song can be looked up again with, as the Now Playing page
// offers them: automatic ("") first, then sourceOrder's names in the default
// order that are switched on (by the same defaults), Apple Music once
// unlocked and in other apps only while allowed there, Musixmatch with
// credentials. None without a song NowLyrics knows in `np` (the app's
// nowplaying.plist).
NSArray<NSString *> *NLOfferedSources(NSDictionary *prefs, NSString *bundleID, NSDictionary *np);
// The source picked for the song in `np` ("" automatic).
NSString *NLPickedSource(NSDictionary *prefs, NSDictionary *np);
// A source's title as the settings' strings have it (their key), and a glyph (SF Symbol).
NSString *NLSourceTitleKey(NSString *name);
NSString *NLSourceSymbolName(NSString *name);

// The song's lyrics as the Now Playing page's song row says them, `localized`
// giving the settings' strings: added by hand, still searching (or `asked`
// from outside and not answered yet: the file still describes the old
// lyrics), saved or fetched and from where, or none found; word by word after.
NSString *NLLyricsStatusText(NSDictionary *np, BOOL asked, NSString *(^localized)(NSString *key));

// `name` picked for the song in `np` (kept in `trackSources` as the page
// keeps it, quietly) and the song looked up again with it (NLLookUpAgain).
// `*prefs` becomes the domain as it is now; returns when it asked, 0 for a
// song without a track key.
CFAbsoluteTime NLPickSourceForSong(NSDictionary **prefs, NSString *bundleID, NSDictionary *np, NSString *name);

// The line being sung and those around it. The line is MediaRemote's title
// (`info`) while NowLyrics has put one there (the song's own title in `np`,
// the app's nowplaying.plist, otherwise); it is found in the lyrics file `np`
// names (parsed once per version, nothing read from disk at a line change
// otherwise) by the position as the island finds it (MediaRemote's elapsed
// time on from its timestamp, the song's offset in `prefs`), or a neighbour
// should the clocks disagree by one, else its first match. Not found: the
// line alone. Between lines (the title the song's own again) no line, the
// one before and those after by the position.
@interface NLSungLines : NSObject
@property (nonatomic, copy) NSString *line;
@property (nonatomic, copy) NSString *previous;              // the last line with words before it
@property (nonatomic, copy) NSArray<NSString *> *next;       // the lines with words after it, as many as asked for
@property (nonatomic, strong) NLShownWords *words;           // its word times as the island lights them; nil for a line-timed one
@property (nonatomic, strong) NSArray<NLLyricLine *> *lines;  // the whole lyrics (the parse's own array: one per version)
@property (nonatomic, assign) NSInteger index;               // the line's in `lines` (between lines the last one started), -1 before the first
@property (nonatomic, assign) NSTimeInterval position;       // where the song is in the lyrics' time (the offset in), as of the call
@property (nonatomic, assign) double rate;                   // and how fast it goes (0 paused)
@end
// nil without lyrics or a title.
NLSungLines *NLSungLinesNow(NSDictionary *np, NSDictionary *info, NSDictionary *prefs, NSUInteger nextCount);

#ifdef __cplusplus
}
#endif
