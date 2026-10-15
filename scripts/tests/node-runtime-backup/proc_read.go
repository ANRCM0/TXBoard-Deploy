package main

import "os"

// Minimal static cat for the network-isolated scratch smoke image. The Node
// process identity probe reads /proc/1/stat and the kernel boot ID before SIGUSR1.
func main() {
	for _, name := range os.Args[1:] {
		body, err := os.ReadFile(name)
		if err != nil {
			os.Exit(1)
		}
		if _, err := os.Stdout.Write(body); err != nil {
			os.Exit(1)
		}
	}
}
