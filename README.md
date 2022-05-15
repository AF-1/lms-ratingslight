Ratings Light
====

A plugin that takes care of rating tracks in your [Logitech Media Server](https://github.com/Logitech/slimserver) library.<br>

#### LMS web ui view:
![LMS web UI](screenshots/lms_webui.jpg)
<br><hr><br>
#### piCorePlayer - *Show more rated tracks by artist* view
![piCorePlayer - Show more rated tracks](screenshots/picoreplayer_show_more_rated_tracks.jpg)
<br><hr><br>
#### Boom - ratings display, rating menu, *show more rated tracks by artist* view
![Boom - ratings menus](screenshots/boom.jpg)
<br><hr><br>
#### *Rated Tracks* browse menus
![Rated Tracks - Home Menu](screenshots/ratedtracksmenu.jpg)
<br><hr><br>
#### *Rated Tracks* context menu
![Rated Tracks - Context Menu](screenshots/contextmenu_years.jpg)<br><br>
(available for artist, album, genre, year and playlist)
<br><hr><br><br>
#### Ratings Light *Settings* pages
![Rated Tracks - Home Menu](screenshots/rl_settings_preview.gif)
<hr><br>

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
* **browse rated tracks by artist or genre**[^1] (with optional library view filter)
* *create* (scheduled) **backups** of your ratings and *restore* your ratings from backups
* keep track of your **recently rated songs** with a dedicated *playlist* or a plain text *log file*
* **show rated songs** for any *artist, album, genre, year* or *playlist* using the respective **context menu** (i.e. song details/**more** page if you're using the LMS *default* skin or *Material* skin)
* provides mixes for **Don't Stop The Music** plugin
* *display track ratings* in *LMS menus* (web UI and text) or on older devices using the *Now Playing screensaver* or the *Music Information Screen* plugin
* most features should work with **online library tracks** (see [**FAQ**](https://github.com/AF-1/lms-ratingslight#faq))

**Some features are not enabled by default.** Please go to the plugin's settings page to enable them.

[^1]: Browse menus are provided by LMS. Under certain circumstances you may see (empty) albums or artists in some menus that shouldn't be there. There's nothing I can do about it because LMS creates and provides these menus.<br>Just go down one level: click to *show all tracks* or *show all albums*.<br>In case this LMS issue ever gets resolved I'll update this page.

<br><br><br><br>


## Installation

You should be able to install *Ratings Light* from *LMS* > *Settings* > *Plugins*.

If you want to test a new patch that hasn't made it into a release version yet or you need to install a previous version, you'll have to [install the plugin manually](https://github.com/AF-1/sobras/wiki/Manual-installation-of-LMS-plugins).

*Previously released* versions are available here for a *limited* time after the release of a new version. The official LMS plugins page is updated about twice a day so it usually takes a couple of hours before new released versions are listed.
<br><br><br><br>


## Translation
The [**strings.txt**](https://github.com/AF-1/lms-ratingslight/blob/main/RatingsLight/strings.txt) file contains all localizable strings. Once you're done **testing** the plugin with your translated strings just create a pull request on GitHub.<br>
* Please try not to use the [**single**](https://www.fileformat.info/info/unicode/char/27/index.htm) quote character (apostrophe) or the [**double**](https://www.fileformat.info/info/unicode/char/0022/index.htm) quote character (quotation mark) in your translated strings. They could cause problems. You can use the [*right single quotation mark*](https://www.fileformat.info/info/unicode/char/2019/index.htm) or the [*double quotation mark*](https://www.fileformat.info/info/unicode/char/201d/index.htm) instead. And if possible, avoid (special) characters that are used as [**metacharacters**](https://en.wikipedia.org/wiki/Metacharacter) in programming languages (Perl), regex or SQLite.
* It's probably not a bad idea to keep the translated strings roughly as long as the original ones.<br>
* Some of these strings are supposed to be used with different UIs: my tests usually cover the LMS *default* skin, *Material* skin, *piCorePlayer* (or any other jivelite player like *SqueezePlay*) and maybe some ip3k player like *Boom* if applicable.
* Please leave *(multiple) blank lines* (used to visually delineate different parts) as they are.
<br><br><br><br>


## Rating character in title format (* or ★)

The default rating character for the title format **RL_RATING_STARS_APPENDED** (*settings > interface*) is the common **asterisk** (*) wrapped in parentheses. Some screenshots here show this title format with the *black star* rating character (★) (see *RL settings > menus*).<br>
If you want to display the **black star** character on *players with jivelite* as graphical frontend (*piCorePlayer, Touch, Radio, SqueezePlay...*), you have to install a font that includes the black star character. [**This page**](https://github.com/AF-1/sobras/tree/main/lms-jivelite-change-font) has more information.
<br><br><br><br>


## Display ratings on the Now Playing screen of piCorePlayer, Squeezebox Touch or Radio

If you've always wanted the **Now Playing** screen of your piCorePlayer, SB Touch, SB Radio or SqueezePlay to **display track ratings**, please read [**this**](https://github.com/AF-1/sobras/tree/main/lms-nowplaying_screen_with_ratings). Here's an example:

![display ratings on the now playing screen of jivelite players](screenshots/ratings_jivelite_npscreen.jpg)
<br><br><br><br><br>


## FAQ
<details><summary>»<b>Does <i>Ratings Light</i> work with <i>online</i> tracks?</b>«</summary><br><p>It should work with online tracks that have been <b>added to your LMS library as part of an album</b>. LMS does not import single online tracks or tracks of online playlists as library tracks and therefore they cannot be processed by Ratings Light. That's a restriction imposed by LMS.</p></details><br>

<details><summary>»<b>Is <i>album</i> rating supported?</b>«</summary><br><p>Short answer: no. <i>Album ratings</i> per se do not exist in LMS. So any displayed album rating would have to be calculated, i.e. the average track rating of all album tracks. Most people have only very few rated tracks in an album, and so you get 'meaningful' (average) album ratings like 0.23 or 0.35.<br>
Setting ratings for an entire album basically tells LMS to set the rating of <b>all</b> album tracks to some value - because there is no album rating other than the calculated one. That would mean: all album tracks would be rated equally - and even the best albums have weak tracks.<br>
So since I'm not convinced that displaying and setting <i>album ratings</i> would be of an use at all, it's not supported.<br>
I'd recommend to add complete albums to the <i>LMS favourites</i> or some static playlist instead.</p></details><br>

<details><summary>»<b>How does <i>importing ratings from file tags</i> work?</b>«</summary><br><p><i>Ratings Light</i> does not scan files, it has no scanner module. LMS scans your music files and stores the data found in the file tags in the LMS database.<br>
<i>Importing rating values from file tags</i> with RL therefore means that RL reads the file tag values stored in the LMS database, converts them to rating values and saves them to the LMS persistent database.<br>
Unfortunately, there is no universal <i>rating tag</i> that is supported by all music file formats across different music players - and scanned/imported by LMS.<br>So in order to import your ratings into LMS, you'll have to use/repurpose a file tag that you don't use otherwise and, more importantly, one that is <b>scanned and imported by LMS</b>.<br><br>
In <i>Ratings Light</i> you can choose between the <b>BPM</b> tag and the <b>comment</b> tag to import ratings values from.<br><br>
RL expects integer rating values on a 10-step rating scale from 0 to 100 in the <b>BPM</b> tag (corresponding to the internal LMS rating scale).<br>→ 0 or no value = unrated<br>→ 10 = 0.5 stars<br>→ 20 = 1 star<br>...<br>→ 100 = 5 stars<br><br>
If you want to use the <b>comment</b> tag, choose at least one short keyword to prefix the rating value. You can also choose a keyword suffix. RL supports importing integer rating values (no half-star ratings) on a scale from 1 to 5.<br>
<b>Example:</b><br>Rating keyword <b>pre</b>fix = "favstars", rating keyword <b>suffix</b> = "xx".<br>If a comment tag contains "favstars<b>4</b>xx", RL will save the track rating value for <b>4</b> stars.
</p></details><br>

<details><summary>»<b>Where does Ratings Light store track ratings?</b>«</summary><br><p><i>Ratings Light</i> does not use its own database. It tells LMS to store the track ratings in the <b>LMS</b> <i>persistent</i> database which is not cleared on rescans. However, if you value your ratings very much, I'd recommend to enable <i>scheduled</i> backups in RL. Or at least create occasional <i>manual</i> backups.</p></details><br>

<details><summary>»<b>Can Ratings Light sync track ratings to <i>music streaming providers</i> or other <i>online services</i>?</b>«</summary><br><p>Short answer: no. Many music streaming providers and online services now use a binary <i>like</i> / <i>heart</i> system to "rate" tracks, albums or artists. But even if some still supported a 5-star rating scale, I simply would not have the time to keep RL compatible with possible (API) changes of all those different services in the long run.<br>If you wanted to reduce 5-star scale track ratings to likes or hearts and sync them to a specific online service, this should be done by the LMS plugin for this specific online services.</p></details><br>

<details><summary>»<b>Can I use a <i>10-star</i> rating scale?</b>«</summary><br><p>If apps still support rating stars, they usually have a 5-star rating scale - also a good idea for LMS because it makes for a consistent user experience. For example, the Material web skin has a 5-star rating scale. There won't be a 10-star rating scale display option in RL. If you really need the extra rating steps, you can enable half-star ratings in the RL settings as a workaround.</p></details><br>

<details><summary>»<b>How is the <i>Recently Rated playlist</i> different from the <i>Recently Rated log</i> file?</b>«</summary><br><p>
In general, whenever you change a track's rating <b>with Ratings Light</b> (web interface, jivelite, CLI...) the track is added to the playlist and/or the log file if you've enabled this in the settings. Both are meant to help you keep track of your rating actions, i.e. the tracks whose rating you've changed.<br>

The <b>recently rated playlist</b> keeps a record of all tracks with changed ratings <b>but</b>
- it will not add a track twice. Example: new rating = 40, then rating = 0 ---> track will only show up only once in the playlist because the playlist shows all tracks whose ratings changed.
- If you unrate a track (rating = 0) it will not delete this track from the playlist because unrating is a rating change too.<br><br>
If you want to keep detailled track of your rating actions and don't need a playable list, I suggest you use the <b>log file</b>.</p></details><br>

<details><summary>»<b>Can I use <i>Ratings Light</i> together with <i>TrackStat</i>?</b>«</summary><br><p>I think you can although I'm not sure it's a good idea, not only because of the UI clutter (you'll have 2 rating menu items in many places). Some apps or plugins that support track rating (like Material skin) will check for TrackStat first (it's been around longer) and if enabled use TrackStat for rating tracks. But then <i>Ratings Light</i> can't know about track rating changes and features like the <i>Recently Rated</i> playlist or the rating log file won't work. There may be other issues. So you can but I don't recommend it.</p></details><br>

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


## Bug reports

If you're **reporting a bug** please **include relevant server log entries and the version number of LMS, Perl and your OS**. You'll find all of that on the  *LMS* > *Settings* > *Information* page.

Please post bug reports only [**here**](https://forums.slimdevices.com/showthread.php?113344-Announce-Ratings-Light).
<br><br>

I'd like to thank *mherger* for his invaluable support and *erland* for his plugins, a great source of inspiration.