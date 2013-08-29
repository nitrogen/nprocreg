-compile(debug).

-type timestamp()		:: {integer(), integer(), integer()}.
-type key() 			:: term().
-type last_contact() 	:: never_expire | timestamp().
