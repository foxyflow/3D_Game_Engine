// Jolt Physics sanity check - run with: odin run jolt_test -p:lib/joltc-odin -extra-linker-flags:"/LIBPATH:."
package main

import "core:fmt"
import joltc "lib:joltc-odin"

main :: proc() {
	fmt.println("Initializing Jolt Physics...")
	ok := joltc.Init()
	if !ok {
		fmt.eprintln("Jolt Init failed!")
		return
	}
	defer joltc.Shutdown()
	fmt.println("Jolt Init OK.")
}
