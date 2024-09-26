xitui is a library for making TUIs in Zig.

* Includes a widget and focus system.
* Widgets are put in a union type defined by the user, rather than using dynamic dispatch.
* Supports Windows and Linux (and probably MacOS but I haven't tested it!).

The only example I have right now is [radargit](https://github.com/radarroark/radargit), a TUI for git. Check out [main.zig](https://github.com/radarroark/radargit/blob/master/src/main.zig) to see how a project is set up.
