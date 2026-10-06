//
//  NLAppleMusicFind.h
//  A song another app plays, found in Apple Music's catalog: its catalog
//  (adam) ID, which Apple Music's lyrics are asked for by. Apple's public
//  search (no account), in the device's region; the result must have the
//  title, and the artist or the length to within 2 s (more than 5 s apart is
//  another version). Titles and artists are compared folded: Traditional as
//  Simplified, no case, accents, widths, bracketed parts or " - …" tails.
//

#import <Foundation/Foundation.h>

// By title and artist, then by title alone. Calls back on the main queue with
// the match (@"id", @"title", @"artist"), or nil and what went
// wrong (nil and nil: not on Apple Music).
void NLFindOnAppleMusic(NSString *title, NSString *artist, NSTimeInterval duration,
                        void (^done)(NSDictionary *match, NSString *problem));
