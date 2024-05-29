Ratings Light
====

**Ratings Light**[^1] takes care of rating tracks in your LMS library. See [**features**](#features) section for details.
<br><br>
<a href="https://github.com/AF-1/">⬅️ <b>Back to the list of all plugins</b></a>
<br><br>
**Use the** &nbsp;![menu icon](https://github.com/AF-1/sobras/blob/main/repos/common/menuicon.svg) &nbsp;**icon** (top right) to **jump directly to a specific section.**

<br><br>


## Screenshots[^3]

#### LMS web ui view:
![LMS web UI](screenshots/lms_webui.jpg)
<br><br><br>
#### piCorePlayer - *Show more rated tracks by artist* view
![piCorePlayer - Show more rated tracks](screenshots/picoreplayer_show_more_rated_tracks.jpg)
<br><br><br>
#### Boom - ratings display, rating menu, *show more rated tracks by artist* view
![Boom - ratings menus](screenshots/boom.jpg)
<br><br><br>
#### *Rated Tracks* browse menus
![Rated Tracks - Home Menu](screenshots/ratedtracksmenu.jpg)
<br><br><br>
#### *Rated Tracks* context menu
![Rated Tracks - Context Menu](screenshots/contextmenu_years.jpg)<br><br>
(available for artist, album, genre, year and playlist)
<br><br><br><br>
#### Ratings Light *Settings* pages
![Rated Tracks - Home Menu](screenshots/rl_settings_preview.gif)
<br><br><br>


## Features

* **set** track ratings
	* in your browser using web skins like *(Dark) Default* or *Material*
	* on your Logitech devices or piCorePlayer (context menu)
	* using the IR remote of your (Logitech) device
	* in supported apps and plugins
	* supports **incremental** rating changes

* **import** track ratings
	* batch rate all tracks in a playlist
	* from file tags
	   * using keywords in *comments* tags (auto-import after scan is possible)
	   * using the *BPM* tag
	   * auto-import after a (re)scan is possible

* **export** rated tracks to playlist files (as a backup or to import ratings in other apps)
* create **virtual libraries for (top) rated tacks** with *browse menus*[^2]
* *create* (scheduled) **backups** of your ratings and *restore* your ratings from backups
* keep track of your **recently rated songs** with a dedicated *playlist* or a plain text *log file*
* **show rated songs** for any *artist, album, genre, year* or *playlist* from the **context menu**
* includes mixes for the **Don't Stop The Music** plugin
* *display track ratings* in *LMS menus* (web UI and text) or on older devices using the *Now Playing screensaver* or the *Music Information Screen* plugin
* most features should work with **online library tracks** (see [FAQ](#faq))

Some features are not enabled by default.

<br><br><br><br>


## Requirements

- LMS version >= **8**.0
- LMS database = **SQLite**

<br>
<a href="https://github.com/AF-1/">⬅️ <b>Back to the list of all plugins</b></a>

<br><br><br>


## Installation

*Ratings Light* is available from the LMS plugin library: **LMS > Settings > Manage Plugins**.<br>

If you want to test a new patch that hasn't made it into a release version yet, you'll have to [install the plugin manually](https://github.com/AF-1/sobras/wiki/Manual-installation-of-LMS-plugins).
<br><br><br><br>


## Reporting a new issue

If you want to report a new issue, please fill out this [**issue report template**](https://github.com/AF-1/lms-ratingslight/issues/new?template=bug_report.md&title=%5BISSUE%5D+).<br><br>
If you use this plugin and like it, perhaps you could give it a :star: so that other users can discover it (in their News Feed). Thank you.
<br><br><br><br>


## Rating character in title format (* or ★)

The default rating character for the title format **RL_RATING_STARS_APPENDED** (*settings > interface*) is the common **asterisk** (*) wrapped in parentheses. Some screenshots here show this title format with the *black star* rating character (★) (see *RL settings > menus*).<br>
If you want to display the **black star** character on *players with jivelite* as graphical frontend (*piCorePlayer, Touch, Radio, SqueezePlay...*), you have to install a font that includes the black star character. [**This page**](https://github.com/AF-1/sobras/tree/main/lms-jivelite-change-font) has more information.
<br><br><br><br>


## Display ratings on the Now Playing screen of piCorePlayer, Squeezebox Touch or Radio

You can install an [**applet**](https://github.com/AF-1#applets) on your *piCorePlayer*, *SB Touch*, *SB Radio* or *SqueezePlay* to **display track ratings** on the **Now Playing** screen. Here's an example:

![display ratings on the now playing screen of jivelite players](screenshots/ratings_jivelite_npscreen.jpg)
<br><br><br><br><br>


## FAQ
<details><summary>»<b>What rating scale does this plugin use?</b>«<br>&nbsp;&nbsp;&nbsp;&nbsp;»<b>Can I use / disable <i>half-star</i> ratings?</b>«</summary><br><p>Rating values are stored in the <i>tracks_persistent</i> database table provided by LMS. <b>Internal rating values in LMS</b> can range <b>from 0 (no stars) to 100 (5 stars) where 20 equals 1 star</b> (40 = 2 stars, 50 = 2.5 stars etc.). So how rating values are stored in LMS is a default that cannot be changed.<br><br><i>Ratings Light</i> will <i>always</i> <b><u>display</u> the exact half-star value</b> on a <b>5</b>-star rating scale (e.g. LMS track rating value of 50 is displayed as 2.5 stars). You can enable or disable <b><i>setting</i> half-star ratings</b> on this page: <i>LMS settings</i> > <i>Advanced</i> > <i>Ratings Lights</i> > <i>Menus</i>.<br>If, for some reason, you have tracks with odd track rating values (e.g. 67), <i>Ratings Light</i> will round them to the nearest half-star rating - <i>for display</i> only, the actual rating values remain unchanged.</p></details><br>

<details><summary>»<b>Is <i>album</i> rating supported?</b>«</summary><br><p><i>“Album ratings“</i> as such do not exist in LMS, only <b>track</b> ratings. You can <b>set</b> a rating for all or only the unrated tracks in an album using the <b>album context menu</b>. Setting ratings for single album tracks in this menu is possible with the Default, Dark Default and Classic web skin.<br><br>RL does <b>not display</b> “album ratings“, i.e. the average track rating of all album tracks. Most albums would probably have a very low average track rating (displayed as zero stars) and you'd have to display the “album rating“ in the album context menu.<br>If you want albums sorted by (average) rating, take a look at the <a href="https://github.com/AF-1/#-context-stats"><b>Context Stats</b></a> plugin.</p></details><br>

<details><summary>»<b>Does <i>Ratings Light</i> work with <i>online</i> tracks?</b>«</summary><br><p>It should work with online tracks that have been <b>added to your LMS library as part of an album</b>. LMS does not import single online tracks or tracks of online playlists as library tracks and therefore they cannot be processed by Ratings Light. That's a restriction imposed by LMS.</p></details><br>

<details><summary>»<b>How do I make <i>Ratings Light</i> display track rating in album view, client playlists etc.?</b>«</summary><br><p>On the <i>LMS Settings</i> > <i>Interface</i> page, you'll find that <i>Ratings Light</i> provides 2 <b>title formats</b>:<br><br><b>RL_RATING_STARS</b> and <b>RL_RATING_STARS_APPENDED</b>.<br><br>You can create a new title format, e.g. “<b>TITLE RL_RATING_STARS_APPENDED</b>“ that will display the track title followed by the track rating value in stars.<br><br>In <i>LMS Settings</i> > <i>Advanced</i> > <i>Ratings Light</i> > <i>Menus</i> you can <b>choose the displayed rating character for menus and titel formats</b>: a <b>common text star</b> or the <b>unicode 2605 blackstar</b> character.<br><br>
<b>Please note:</b> <i>SB Touch, SB Radio, piCorePlayer, Squeezeplay and other players running jivelite</i> do not support displaying the unicode blackstar character out of the box. This character is not part of their default font. If you want to display this character on these devices you'll have to replace the default font on these devices with a font that contains this character.<br>
More information, instructions, and fonts <a href="https://github.com/AF-1/sobras/tree/main/lms-jivelite-change-font">here</a>.<br>The <b>Material</b> web skin uses its own way to display track ratings in menus and playlists.</p></details><br>


<details><summary>»<b>Where does Ratings Light store track ratings?</b>«</summary><br><p><i>Ratings Light</i> does not use its own database. It tells LMS to store the track ratings in the <b>LMS</b> <i>persistent</i> database which is not cleared on rescans. However, if you value your ratings very much, I'd recommend to enable <i>scheduled</i> backups in RL. Or at least create occasional <i>manual</i> backups.</p></details><br>

<details><summary>»<b>Does <i>Ratings Light</i> auto-rate tracks when I play or skip them?</b>«</summary><br><p>No. Please use the <a href="https://github.com/AF-1/#-alternative-play-count"><b>Alternative Play Count</b></a> plugin for that. It can auto-rate tracks and offers you an alternative, the <b>dynamic played/skipped value</b> that reflects your <b>recent</b> listening habits/decisions but does not mess with your tracking ratings.</p></details><br>

<details><summary>»<b>How do I migrate ratings from <i>TrackStat</i> to <i>Ratings Light</i>?</b>«</summary><br><p>You don't have to. Since ratings are stored in an LMS database (see FAQ above), you just <b>un</b>install <i>TrackStat</i> and install <i>Ratings Light</i>. TrackStat had its own database table (with identical columns though) but <i>ratings</i> should be in sync. You can even import ratings for <i>local</i> tracks from old TrackStat backup files.</p></details><br>

<details><summary>»<b>How does <i>importing ratings from file tags</i> work?</b>«</summary><br><p><i>Ratings Light</i> does not scan files, it has no scanner module. LMS scans your music files and stores the data found in the file tags in the LMS database.<br>
<i>Importing rating values from file tags</i> with RL therefore means that RL reads the file tag values stored in the LMS database, converts them to rating values and saves them to the LMS persistent database.<br>
Unfortunately, there is no universal <i>rating tag</i> that is supported by <b<all</b> music file formats across different music players - and scanned/imported by LMS.<br>So in order to import your ratings into LMS, you'll have to use/repurpose a file tag that you don't use otherwise and, more importantly, one that is <b>scanned and imported by LMS</b>.<br><br>
In <i>Ratings Light</i> you can choose between the <b>BPM</b> tag and the <b>comments</b> tag to import ratings values from.<br><br>
RL expects integer rating values on a 10-step rating scale from 0 to 100 in the <b>BPM</b> tag (corresponding to the internal LMS rating scale).<br>→ 0 or no value = unrated<br>→ 10 = 0.5 stars<br>→ 20 = 1 star<br>...<br>→ 100 = 5 stars<br><br>
If you want to use the <b>comments</b> tag, choose at least one short keyword to prefix the rating value. You can also choose a keyword suffix. RL expects integer rating values (<b>no half-star ratings</b>) on a scale from 1 to 5 for importing from comments tags.<br>
<b>Example:</b><br>Rating keyword <b>pre</b>fix = "favstars", rating keyword <b>suffix</b> = "xx".<br>If a comments tag contains "favstars<b>4</b>xx", RL will save the track rating value for <b>4</b> stars.
</p></details><br>

<details><summary>»<b>When I create a backup, RL <i>does not write a backup file</i>.</b>«<br>&nbsp;&nbsp;&nbsp;&nbsp;»<b>When I <i>export rated tracks to playlist files</i>, RL does not write any playlist files.</b>«</summary><br><p>
The <i>RatingsLight</i> folder is where RL stores its backup files and playlist files. On every LMS (re)start, RL checks if there's a folder called <i>RatingsLight</i> in the parent folder. The default <b>parent</b> folder is the <i>LMS preferences folder</i> but you can change that in RL's preferences. If it doesn't find the folder <i>RatingsLight</i> inside the specified parent folder, it will try to create it.<br><br>
The most likely cause is that RL can't create the folder because LMS doesn't have read/write permissions for the parent folder (or the <i>RatingsLight</i> folder). You'll probably find matching error messages in the server log.<br><br>
So please make sure that <b>LMS has read/write permissions (755) for the <i>parent</i> folder - and the <i>RatingsLight</i> folder</b> (if it exists but cannot be accessed).
</p></details><br>

<details><summary>»<b>Can Ratings Light sync track ratings to <i>music streaming providers</i> or other <i>online services</i>?</b>«</summary><br><p>Short answer: no. Many music streaming providers and online services now use a binary scheme (e.g. called <i>like</i> or <i>heart</i>) to "rate" tracks, albums or artists. But even if some still supported a 5-star rating scale, I simply would not have the time to keep RL compatible with possible (API) changes of all those different services in the long run.<br>If you wanted to reduce star track ratings to binary likes or hearts and sync them to a specific online service, this should be done by the LMS plugin for this specific online services.</p></details><br>

<details><summary>»<b>Can I use CLI commands to set ratings?</b>«</summary><br><p>
Explained in the <a href="https://github.com/AF-1/lms-ratingslight/wiki/CLI-commands">wiki</a>.
</p></details><br>

<details><summary>»<b>Can I use <i>Ratings Light</i> together with <i>TrackStat</i>?</b>«</summary><br><p>You really shouldn't. If you rate tracks with <i>Ratings Light</i>, these rating changes will be lost the next time you restart your server because TrackStat will reset the LMS database ratings to the TrackStat database values.</p></details><br>

<details><summary>»<b>Does <i>Ratings Light</i> work with <i>iPeng</i>?</b>«</summary><br><p>Displaying and changing track ratings in iPeng is already possible via the <b>context menu</b>.<br>iPeng <b>additionally</b> offers the possibility to display and change track ratings directly in the <b>top left menu bar</b>. iPeng has no official support for <i>Ratings Light</i> yet.<br>However, you'll find a workaround in the <i>Menus</i> section of the RL settings that should allow you to display and change track ratings directly in iPeng's top left menu bar (requires an LMS restart).</p></details><br>

<details><summary>»<b>How is the <i>Recently Rated playlist</i> different from the <i>Recently Rated log</i> file?</b>«</summary><br><p>
In general, whenever you change a track's rating <b>with Ratings Light</b> (web interface, jivelite, CLI...) the track is added to the playlist and/or the log file if you've enabled this in the settings. Both are meant to help you keep track of your rating actions, i.e. the tracks whose rating you've changed.<br>


The <b>recently rated playlist</b> keeps a record of all tracks with changed ratings <b>but</b>
- it will <b>not add tracks twice</b>. Example: Set a track's rating to 4 stars, then set it to 2 stars. The track will only show up only once in the playlist with the <b>latest</b> rating (2 stars), <b>no matter how often</b> you have changed its rating.
- <b>Un</b>rating a track (rating = 0) will not delete this track from the playlist because unrating is a rating change too.<br>

If you want to keep detailed track of your rating actions and don't need a playable list, I suggest you use the <b>log file</b>.</p></details><br>
<br><br><br>

[^1]: If you want localized strings in your language, please read <a href="https://github.com/AF-1/sobras/wiki/Adding-localization-to-LMS-plugins"><b>this</b></a>.
[^2]: Browse menus are provided by LMS. Under certain circumstances you may see (empty) albums or artists in some menus that shouldn't be there. There's nothing I can do about it because LMS creates and provides these menus.<br>Just go down one level: click to *show all tracks* or *show all albums*.<br>In case this LMS issue ever gets resolved, I'll update this page.
[^3]: The screenshots might not correspond to the UI of the latest release in every detail.

