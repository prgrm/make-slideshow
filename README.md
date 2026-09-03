FFmpeg QSV Slideshow Generator

A PowerShell-based slideshow generator using FFmpeg and Intel Quick Sync Video (QSV) to combine photos and videos into a chronological slideshow.

Features

Intel QSV HEVC (hevc_qsv) encoding

Portrait, landscape, or both orientations

Portrait output: 1080x1440

Landscape output: 1440x1080

Chronological sorting from the filename timestamp

Date-based chapters

Date displayed at the start of each new date

JPG, JPEG, PNG, MOV, MP4, and M4V support

Image EXIF orientation detection

Video rotation metadata used for orientation classification

Source videos are not intentionally rotated

Blurred backgrounds for mismatched orientations

Slow Ken Burns effect on images

Crossfades between clips

Original video audio preserved

Optional background music

Music automatically ducks to 40% while original video audio is playing

No music fade-in or fade-out

Batch processing for large collections

Debug filter graphs saved when processing batches

Filename Format

The filename must contain a timestamp in this format:

YYYYMMDD_HHMMSS.extension

Example:

20260902_111213.jpg
20260902_111530.mp4
20260902_124501.mov

For example:

20260902_111213.jpg

means:

September 2, 2026 at 11:12:13

The filename timestamp is the authoritative source for:

Sorting

Date/time display

Date detection

Chapter creation

Slideshow chronology

The script does not use the filesystem's LastWriteTime.

Files that do not match the required filename format are skipped.

Requirements

Windows

PowerShell

FFmpeg

FFprobe

An Intel GPU with compatible Quick Sync support

An FFmpeg build containing the hevc_qsv encoder

Check FFmpeg:

ffmpeg -version

Check FFprobe:

ffprobe -version

Check QSV encoders:

ffmpeg -encoders | findstr qsv

You should see hevc_qsv.

Installation

Install FFmpeg.

Add FFmpeg to the Windows PATH.

Verify that both ffmpeg and ffprobe work from PowerShell.

Place slideshow.ps1 in your media directory, or specify another directory with -Path.

Basic Usage

Run:

.\slideshow.ps1

The script asks:

Include media: [P]ortrait, [L]andscape, or [B]oth? (Default: B)

Choose:

P — Portrait

L — Landscape

B — Both

Output

Portrait

1080x1440

Default filename:

slideshow_Portrait.mp4

Landscape

1440x1080

Default filename:

slideshow_Landscape.mp4

Both

The default output dimensions remain:

1080x1440

Landscape media is fitted into the portrait frame with a blurred background.

Default filename:

slideshow_Both.mp4

Orientation Handling

When source and output orientations differ, the script:

Creates a blurred background.

Fits the original media inside the output frame.

Centers the original media over the blurred background.

This avoids cropping the main content.

Images

Still images receive a slow Ken Burns-style zoom.

Images are rendered at an enlarged resolution before the final resize to create smooth movement.

The default still-image duration is 4 seconds.

Videos

Video files retain their source orientation.

Rotation metadata is read to correctly classify the video as portrait or landscape, but the source is not intentionally rotated.

Audio

Original video audio

Audio from videos that contain an audio stream is preserved and mixed into the slideshow timeline.

Background music

The script checks the working directory for:

music2.mp3
music.mp3
music2b.mp3

The first matching file is used.

Music volume

Normal background music:

100%

While original video audio is playing:

40%

Music switches directly between these levels. There is no fade-in or fade-out.

Chapters

A new chapter is created whenever the filename date changes.

For example:

20260901_100000.jpg
20260901_110000.jpg
20260901_130000.mp4
20260902_090000.jpg
20260902_120000.jpg

produces chapters for:

2026-09-01
2026-09-02

Chapter positions are based on the slideshow timeline.

Sorting

Files are sorted using the timestamp extracted from the filename.

Example:

20260902_111213.jpg
20260902_111500.jpg
20260902_123000.jpg
20260903_080000.jpg

will always appear in that order.

Filesystem modification dates have no effect on the slideshow order.

This is useful when files have been copied, backed up, synchronized, or moved between systems.

Batch Processing

The script processes media in batches to limit resource usage.

Default:

30 items per batch

Progress is displayed like:

Processing Batch 11 of 24 (30 items)
Generating FFmpeg filter graph for batch 11/24...

Change the batch size with:

.\slideshow.ps1 -BatchSize 20

or:

.\slideshow.ps1 -BatchSize 50

A smaller batch size can reduce peak memory usage.

Parameters

-Path

Directory containing media.

Default:

.

Example:

.\slideshow.ps1 -Path "D:\Vacation"

-InputFiles

Explicit files or wildcard patterns.

Example:

.\slideshow.ps1 -InputFiles "D:\Photos\20260902_*.jpg"

Multiple patterns:

.\slideshow.ps1 `
    -InputFiles "D:\Photos\*.jpg","D:\Videos\*.mp4"

-Filter

File patterns used when -InputFiles is not supplied.

-OutputFile

Custom output filename.

Example:

.\slideshow.ps1 -OutputFile "vacation.mp4"

The selected orientation is appended automatically:

vacation_Portrait.mp4

-DurationSeconds

Default duration for still images.

Default:

4

Example:

.\slideshow.ps1 -DurationSeconds 5

-FadeSeconds

Crossfade duration.

Default:

1

Example:

.\slideshow.ps1 -FadeSeconds 2

-Fps

Output frame rate.

Default:

30

Example:

.\slideshow.ps1 -Fps 60

-BatchSize

Number of media items per batch.

Default:

30

Example:

.\slideshow.ps1 -BatchSize 20

Examples

Process the current directory:

.\slideshow.ps1

Process another directory:

.\slideshow.ps1 -Path "D:\Vacation"

Use five-second still images:

.\slideshow.ps1 -DurationSeconds 5

Use two-second crossfades:

.\slideshow.ps1 -FadeSeconds 2

Use a smaller batch size:

.\slideshow.ps1 -BatchSize 20

Temporary Files

During processing the script creates temporary batch files such as:

temp_batch_0.mp4
temp_batch_1.mp4
temp_batch_2.mp4

It also creates:

concat.txt
metadata.txt
filter_batch_0.txt
filter_batch_1.txt

Temporary files are removed after successful completion.

If FFmpeg fails, temporary batch files and the relevant filter graph are retained to assist troubleshooting.

Troubleshooting

FFmpeg not found

Run:

ffmpeg -version

If it fails, install FFmpeg and add its directory to PATH.

FFprobe not found

Run:

ffprobe -version

QSV unavailable

Run:

ffmpeg -encoders | findstr qsv

Verify that hevc_qsv is available and that the Intel graphics driver supports Quick Sync.

Files are skipped

Check the filename format.

Valid:

20260902_111213.jpg

Invalid:

IMG_1234.jpg
202692_91500.jpg
vacation.jpg

The required pattern is exactly:

YYYYMMDD_HHMMSS

Incorrect slideshow order

Verify that the filenames contain valid zero-padded timestamps.

Correct:

20260902_091500.jpg
20260902_101500.jpg
20260902_111500.jpg

Performance

Video encoding uses:

hevc_qsv

with:

-global_quality 25

Lower values generally increase quality and file size. Higher values generally reduce quality and file size.

Some filtering remains CPU-based, including scaling, blur, overlay, zoompan, drawtext, and xfade.

Output Specifications

Video

Codec: HEVC / H.265

Encoder: Intel Quick Sync (hevc_qsv)

Default frame rate: 30 FPS

Pixel format: NV12

Audio

Codec: AAC

Bitrate: 192 kbps

Suggested Project Structure

Slideshow/
├── slideshow.ps1
├── README.md
├── 20260901_091500.jpg
├── 20260901_102300.jpg
├── 20260901_134500.mp4
├── 20260902_081200.jpg
├── 20260902_111213.mov
├── music2.mp3
└── output/

Why Filename Timestamps?

Filesystem timestamps can change when media is:

Copied to another drive

Restored from backup

Synchronized through cloud storage

Moved between operating systems

Imported from another device

Using the timestamp embedded in the filename keeps the intended chronological order independent of filesystem metadata.

License

Choose and add a license appropriate for your project before publishing it to GitHub.

For an open-source project, the MIT License is one possible option.

Author

PowerShell/FFmpeg workflow for automated photo and video slideshow generation using Intel Quick Sync hardware acceleration.
