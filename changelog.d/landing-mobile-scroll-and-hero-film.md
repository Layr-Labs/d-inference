### Smoother landing page on phones

- The homepage map animation no longer restyles and repaints all of its tiles on every scroll frame; tile outlines and the dive fade move in small steps instead, which removes most of the scroll stutter on iPhone.
- The hero film is served as a 3.9 MB phone crop or an 11.9 MB 1080p cut, both without the unused audio track (previously one 43.5 MB file at 14.7 Mbps), with a JPEG poster. It pauses once it has landed in the map, and the closing laptop loop plays only while on screen.
- On phones the hero headline fades before the film shrinks away from it, the chat panel no longer touches "See it route, right now", and tapping the chat field no longer zooms the page. Once a question is asked, the suggested questions give their room to the answer, which small phones such as the iPhone SE had no space to show.
- Media under `/media/` is cached for a day instead of revalidating on every visit. Low Power Mode still shows the poster instead of the film, as iOS requires.
