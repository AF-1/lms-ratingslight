Ratings Light
====

A plugin that takes care of rating tracks in your [Logitech Media Server](https://github.com/Logitech/slimserver) library.<br>

#### LMS web ui view:
![LMS web UI](screenshots/lms_webui.jpg)
<br><br>
#### piCorePlayer - *Show more rated tracks by artist* view
![piCorePlayer - Show more rated tracks](screenshots/picoreplayer_show_more_rated_tracks.jpg)
<br><br>
#### Boom - ratings display, rating menu, *show more rated tracks by artist* view
![Boom - ratings menus](screenshots/boom.jpg)
<br><br>
#### *Rated Tracks* browse menus
![Rated Tracks - Home Menu](screenshots/ratedtracksmenu.jpg)
<br><br>
#### *Rated Tracks* context menu
![Rated Tracks - Context Menu](screenshots/contextmenu_years.jpg)<br><br>
(available for artist, album, genre, year, and playlist)
<br><br><br>

## Requirements

- LMS version >= 7.**9**
- LMS database = **SQLite**
<br><br><br>

## Features:

* **set** track ratings (supports **incremental** rating changes)
	* in your browser using the *default LMS* or the *Material* skin web UI
	* on your Logitech devices or piCorePlayer (context menu)
	* using the IR remote of your (Logitech) device
	* in supported apps and plugins

* **import** track ratings
	* batch rate all tracks in a playlist
	* using keywords in comment tags (auto-import after scan is possible)

* **export** rated tracks to playlist files (as a backup or to import ratings in other apps)
* **browse rated tracks by artist or genre** (with optional library view filter)
* *create* (scheduled) **backups** of your ratings and *restore* your ratings from backups
* keep track of your **recently rated songs** with a dedicated *playlist* or a plain text *log file*
* **show rated songs** for *artist, album, genre, year, playlist* - one click away from the song details/more page (webUI, Material) or from the context menu (Radio, Touch, piCorePlayer)
* provides mixes for **Don't Stop The Music** plugin
* *display track ratings* in *LMS menus* (web UI and text) or on older devices using the *Now Playing screensaver* or the *Music Information Screen* plugin
* most features should work with **online library tracks** (see [**FAQ**](https://github.com/AF-1/lms-ratingslight#faq))

**Some features are not enabled by default.** Please go to the plugin's settings page to enable them.<br><br>
<br><br><br><br>

## Installation, bug reports

You should be able to install *Ratings Light* from *LMS* > *Settings* > *Plugins*.

If you want to test a new patch that hasn't made it into a release version yet or you need to install a previous version you'll have to [install the plugin manually](https://github.com/AF-1/sobras/wiki/Manual-installation-of-LMS-plugins).

*Previously released* versions are available here for a *limited* time after the release of a new version. The official LMS plugins page is updated about twice a day so it usually takes a couple of hours before new released versions are listed.


If you're **reporting a bug** please **include relevant server log entries and the version number of LMS, RL and your OS**. You'll find all of that on the *LMS > Settings > Information* page.

Please post bug reports only [**here**](https://forums.slimdevices.com/showthread.php?113344-Announce-Ratings-Light).
<br><br><br><br>

## Translation
The [**strings.txt**](https://github.com/AF-1/lms-ratingslight/blob/main/RatingsLight/strings.txt) file contains all localizable strings. Once you're done testing the plugin with your translated strings just create a pull request on GitHub. If that doesn't work for you post the updated file as an attachment in the [forum](https://forums.slimdevices.com/showthread.php?113344-Announce-Ratings-Light).<br><br>
It's probably not a bad idea to keep the translated sentences roughly as long as the original ones and to avoid special characters.<br>
Please keep in mind that some of these strings are supposed to be displayed on different UIs. My tests usually cover the LMS default skin, piCorePlayer and maybe Boom if applicable.
<br><br><br><br>


## Rating character in title format (* or ★)

The default rating character for the title format **RL_RATING_STARS_APPENDED** (*settings > interface*) is the common **asterisk** (*) wrapped in parentheses. Some screenshots here use this title format with the *black star* rating character (★) (see *RL settings > menus*).<br>
If you want to display the **black star** character on *players with jivelite* as graphical frontend (*piCorePlayer, Touch, Radio, SqueezePlay...*) you have to install a font that includes the black star character. If you're interested please visit [**this page**](https://github.com/AF-1/sobras/tree/main/lms-jivelite-change-font) for more information.
<br><br><br><br>

## Display ratings on the Now Playing screen of piCorePlayer, Squeezebox Touch or Radio

If you've always wanted the **Now Playing** screen of your piCorePlayer, SB Touch, SB Radio or SqueezePlay to **display track ratings**, please read [**this**](https://github.com/AF-1/sobras/tree/main/lms-nowplaying_screen_with_ratings). Here's an example:

![display ratings on the now playing screen of jivelite players](screenshots/ratings_jivelite_npscreen.jpg)
<br><br><br><br>


## FAQ
<details><summary>»<b>Can I use <i>Ratings Light</i> together with <i>TrackStat</i>?</b>«</summary><br><p>I think you can although I'm not sure it's a good idea, not only because of the UI clutter (you'll have 2 rating menu items in many places). Some apps or plugins that support track rating (like Material) will check for TrackStat first (it's been around longer) and if enabled use TrackStat for rating tracks. But then <i>Ratings Light</i> can't know about track rating changes and features like the <i>Recently Rated</i> playlist or the rating log file won't work. There may be other issues. So you can but I don't recommend it.</p></details><br>

<details><summary>»<b>Does <i>Ratings Light</i> work with <i>online</i> tracks?</b>«</summary><br><p>It should work with online tracks that have been <b>added to your LMS library as part of an album</b>. LMS does not import single online tracks or tracks of online playlists as library tracks and therefore they cannot be processed by Ratings Light. That a LMS restriction.</p></details><br>

<details><summary>»<b>How is the <i>Recently Rated playlist</i> is different from the <i>Recently Rated log</i> file?</b>«</summary><br><p>
In general, whenever you change a track's rating <b>with Ratings Light</b> (web interface, jivelite, CLI...) the track is added to the playlist and/or the log file if you've enabled this in the settings. Both are meant to help you keep track of your rating actions, i.e. the tracks whose rating you've changed.<br>

The <b>recently rated playlist</b> keeps a record of all tracks with changed ratings <b>but</b>
- it will not add a track twice. Example: new rating = 40, then rating = 0 ---> track will only show up only once in the playlist because the playlist shows all tracks whose ratings changed.
- If you unrate a track (rating = 0) it will not delete this track from the playlist because unrating is a rating change too.<br>

If you want to keep detailled track of your rating actions and don't need a playable list I suggest you use the <b>log file</b>.</p></details><br>

<br><br>
## Note for developers

**setrating cli command**:<br>
* `['ratingslight', 'setrating', 'trackid', 'rating', 'incremental']` (expects a rating value in the range of 0 to 5, half-star ratings supported)
* `['ratingslight', 'setratingpercent', 'trackid', 'rating', 'incremental']` (expects a rating value in the range of 0 to 100)


Example: the command `['ratingslight', 'setrating', 'track_id:12345', 'rating:3.5']` will store a rating value of 70 (3.5 stars * 20) in the database for the track with the track_id:12345.
<br><br>

**incremental rating**:<br>
use the incremental parameter with **+** or **-** to **add/subtract** a rating value to/from the **current** rating value.

*Example 1*: the command `['ratingslight', 'setrating', 'track_id:12345', 'rating:1', 'incremental:+']` will add 1 star to the current rating value of the track with the track_id:12345.

*Example 2*: You could use incremental rating changes with the KidsPlay plugin. Map this command to a button on your Boom or Radio to increase the current track's rating by 1 star (replace + with - to decrease rating):
`ratingslight setrating track_id:{CURRENT_TRACK_ID} rating:1 incremental:+;`
<br><br>

You can also **get notified of track rating changes** by *subscribing* to
* *applets*: `/slim/ratingslightchangedratingupdate`
* *plugins*: `['ratingslight', 'changedrating']`
<br><br><br><br>



### One minor known issue

The (optional) menus for browsing rated tracks by artist or genre are provided by LMS (extended browse modes). Under certain circumstances you may see albums listed for an artist (artists menu) or artists for a genre (genres menu) that shouldn't be there. There's nothing I can do about it because LMS creates and provides these menus.

Easy solution: just go down one level, i.e. Show all tracks (artists menu) or Show all albums (genres menu), and the problem has vanished. That's the way I do it.
Or you could completely rebuild these menus with CustomBrowse which uses its own browse logic and menus (instead of the ones provided by LMS) and therefore doesn't have this bug.
In case this issue ever gets resolved I'll update this page.
<br><br>
I'd like to thank [mherger](https://github.com/mherger) for his invaluable support and [erland](https://github.com/erland) for his plugins, a great source of inspiration.