In a scratch file, we'll define two terms.
- `runnable`: a properly typed term that can be `run`
- `badtype`: an improperly typed term that cannot be `run`

```unison
---
title: scratch.u
---
runnable : '{builtin.io.IO} ()
runnable = '(printLine "hello!")

badtype : Text ->{builtin.io.IO} ()
badtype = 'printLine "hello!"

```


```ucm

  I found and typechecked these definitions in scratch.u. If you
  do an `add` or `update`, here's how your codebase would
  change:
  
    ⍟ These new definitions are ok to `add`:
    
      badtype  : Text ->{io.IO} ()
      runnable : '{io.IO} ()

```
Since `runnable` is properly typed, Unison will successfully `run` it (the "hello" output does not show up in this transcript):
```ucm
.> run runnable

```
When we run the term with the bad type, we get an error message that lets us know that Unison found the term, but the type is not `run`able:

```ucm
.> run badtype

  😶
  
  I found this function:
  
    badtype : builtin.Text ->{builtin.io.IO} ()
  
  but in order for me to `run` it it needs to have the type:
  
    badtype : '{builtin.io.IO} a

```
When we run a term that Unison cannot find at all, we get an error message that the term could not be found:

```ucm
.> run notfound

  😶
  
  I looked for a function `notfound` in the most recently
  typechecked file and codebase but couldn't find one. It has to
  have the type:
  
    notfound : '{builtin.io.IO} a

```
Now let's add these terms to the codebase and clear our scratchfile, to show that the behavior is consistent if the terms are found inside the codebase.

```ucm
.> add

  ⍟ I've added these definitions:
  
    badtype  : Text ->{io.IO} ()
    runnable : '{io.IO} ()

```
```unison
---
title: scratch.u
---

```


```ucm

  I loaded scratch.u and didn't find anything.

```
```ucm
.> run runnable

```
```ucm
.> run badtype

  😶
  
  I found this function:
  
    badtype : builtin.Text ->{builtin.io.IO} ()
  
  but in order for me to `run` it it needs to have the type:
  
    badtype : '{builtin.io.IO} a

```
