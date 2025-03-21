---
{
  "title": "Hello, files!"
}
---

Instead of writing a simple message to the terminal, let's write it to a file,
read it back, _then_ write that to the terminal. Isn't that exciting!

To start, create the file `files.inko` with the following contents:

```inko
import std.fs.file (ReadWriteFile)
import std.stdio (Stdout)

type async Main {
  fn async main {
    let out = Stdout.new
    let file = ReadWriteFile.new('hello.txt'.to_path).get
    let bytes = ByteArray.new

    file.write('Hello, world!').get
    file.seek(0).get
    file.read_all(bytes).get
    out.write(bytes).get
  }
}
```

Now run it using `inko run files.inko`, and the output should be:

```
Hello, world!
```

There will also be a file called `hello.txt` in your current working directory,
containing the same message.

## Explanation

We used `ReadWriteFile` to open a file for both reading and writing, using
`'hello.txt'` as the path to the file. We then write the message to it, reset
the cursor to the start of the file, then read the data back, and write it to
the terminal.

For the sake of brevity we've ignored error handling by using `get`,
resulting in the program terminating in the event of an error. Of course in a
real program you'll want more fine-grained error handling, but for the sake of
brevity we'll pretend our program won't produce any errors.

In case you're wondering: there's no need to close the file handles yourself, as
this is done automatically. Neat!

## Read-only files

If we just want to read a file, we'd do so as follows:

```inko
import std.fs.file (ReadOnlyFile)
import std.stdio (Stdout)

type async Main {
  fn async main {
    let out = Stdout.new
    let file = ReadOnlyFile.new('hello.txt'.to_path).get
    let bytes = ByteArray.new

    file.read_all(bytes).get
    out.write(bytes).get
  }
}
```

If you run this and `hello.txt` still exists in the current working directory,
the output is the contents of this file. If the file doesn't exist, you'll see
an error such as this:

```
Stack trace (the most recent call comes last):
  [...]/files.inko:7 in main.Main.main
  [...]/std/src/std/result.inko:119 in std.result.Result.get
  [...]/std/src/std/process.inko:15 in std.process.panic
Process 'Main' (0x5645bdf31740) panicked: Result.get expects an Ok(_), but an Error(_) is found
```

## Write-only files

If you just want to write to a file, you'd use the `WriteOnlyFile` type:

```inko
import std.fs.file (WriteOnlyFile)

type async Main {
  fn async main {
    let file = WriteOnlyFile.new('hello.txt'.to_path).get

    file.write('Hello, world!')
  }
}
```

If you run this program, no output is produced; instead it writes "Hello,
world!" to the file `hello.txt` in the current working directory.
