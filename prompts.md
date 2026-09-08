Perform an in-depth enhancement of the client part of the SEAD browser system (sead_browser_client repository).

This shall all be done within the confines of the git branch called master-review.

Go through the entire sead browser at https://sead.local/ and look at every little detail. Evaluate the "look and feel" of everything. We should strive for consistency in design language, along with professionalism and scientific excellence.

Everyting needs to be clearly readable, graphs needs to be pedagagical, logical and factually correct. Text needs to be legible.

Consider everything from both a desktop and mobile rendering mode. The desktop mode should be considered to be the primary one. If the sead browser system is not fully functional in every way in mobile mode, then that is a compromise we might be willing to make, but we should strive to make it as functional as can be even in this mode. Although not at the expensive of desktop functionality.

Test run all functions, click on all buttons and open all dialogs etc. Check for any case of bad rendering, such as cases where one element which is clearly meant to be underneath instead ends up on top. For example, perhaps a tab of the underlying interface renders on top of a pop up modal, this would clearly be a bug that shoudl be fixed.

Also check the entire site for rendering performance. How can it be improved without losing functionality? Both network package sizes and in-browser rendering performance (memory consumption, threads, cpu processing, gpu, cost of graphical effects, etc) matters.

Evaluate and improve where it's possible without degradation in look and feel or quality.

Click on everything and look for bugs, errors, rendering artifacts, glitches etc. and fix. Test everything and fix accordingly.

Perform spot checks (random sampling) where you verify that information shown in the sead browser client user interface reflects accurately what is actually in the database. Use the PostgREST API to query the database directly for the raw data.

Keep iterating all of the above points until you have meticulously gone through every part of the sead browser client and checked everything you can think of.

Everything you do needs to be written down. You shall log everything you do in the git commit messages. And everything shall be committed to the master-review branch.

You shall also create a document in the root of this folder called "master-review-report.md" which contains a brief of all the git commits along with suggestions for improvements you did not want to perform without a go ahead and other things which might have popped up during the interview and which might be good to know.

