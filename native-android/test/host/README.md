Host-JVM stand-ins for the few Android platform classes the engine calls
directly while running `EngineTests`. They are compiled ahead of `android.jar`
only for the host checks (`npm run test:android`) and are never part of
`opencu-android.jar`.
