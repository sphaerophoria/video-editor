# Video editor for specifically me

Developed live on [twitch](https://twitch.tv/sphaerophoria) and [youtube](https://youtube.com/playlist?list=PL980gcR1LE3IrSp9xkLHvogSs1QaaDIwu&si=EDrkx6xe_U1GqJvd)

## Elevator pitch
* Streams produce long videos
* Maybe short videos are better
* Cutting stuff down is hard
* Can we make it easier?

## Expected features
* Auto generate subtitles for video
* Attach subtitles to timeline. E.g. clicking on a word will take us to that position
* Create ranges of video that are either marked as used or unused
* Preview what the re-rendered video will look/sound like interactively
* Export the shortened video. Doing as little re-encoding as possible

```
      Video playback
             v
  --------------------------------------
  ||               |todo  ||| ~~~      |
  ||  Code         |~~~~  |||          |
  ||   goes        |~~    ||| ~~~~~~   |
  ||    here       |      ||| ~~~~~    | <-- script
  ||               |me    ||| ~I~~~~~  |
  ||               |------|||          |
  ||               |   o  |||          |
  ||               |  -|- |||          |
  |------------------------------------|
  | ---------o-----------------------  | <-- timeline
  --------------------------------------

```
