// Entry point. No @main anywhere in this target: ArgumentParser and SwiftUI
// both want it, so both are invoked manually — LabelKitCommand.main() here,
// LabelKitApp.main() from LabelKitCommand.run() once arguments are validated.
LabelKitCommand.main()
