xitui is a library for making TUIs in Zig (requires version 0.15.1).

* Includes a widget and focus system.
* Widgets are put in a union type defined by the user, rather than using dynamic dispatch.
* Supports Windows, MacOS and Linux.

The only example I have right now is [radargit](https://github.com/radarroark/radargit), a TUI for git. Check out [main.zig](https://github.com/radarroark/radargit/blob/master/src/main.zig) to see how a project is set up.
