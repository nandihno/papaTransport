# Train Line Status widget

## V1 scope

PapaTransport includes a configurable **Train Line Status** widget for
Melbourne Metro lines. Each widget instance selects its own line in the widget
configuration editor. V1 is line-wide: it has no station field. A later commute
widget can use the selected origin and destination stations to show departures.

The small family shows the line, service state, a short status message, and the
last successful update. The medium family separates the line and status from
the latest alert, and also shows the first planned-works notice when one is
available. Rail, service-state, alert, planned-works, and update symbols make
the information easier to scan; text and color still identify every state.
Tapping the widget opens PapaTransport.

## Data and refresh

The widget extension calls the existing `TrainService` and the same
`website_data.json` feed as the app. `TrainLineStatusIntent` obtains the
available lines from `fetchTrainLines()`, so the configuration choices stay in
step with the app's line picker. Each widget timeline fetches status for its
configured line, then caches the last successful entry in the extension's
local defaults. If a refresh fails, the widget keeps that entry and labels it
as saved status; if no successful result exists, it shows an unavailable state.

The timeline requests another refresh after 30 minutes. WidgetKit schedules
that refresh subject to system policy, so the widget is a glanceable status
summary rather than a guaranteed live monitor. The displayed update time lets
the user judge how recent the data is.

## Implementation and validation

- The WidgetKit extension is a separate `PapaTransportWidgets` target embedded
  in the iOS app.
- Shared train status models live in `PapaTransport/Models/TrainStatusModels.swift`;
  both the app and extension compile the same model definitions.
- The widget does not require an App Group. Its configuration is per instance,
  and the extension makes its own requests and keeps its own fallback cache.
- Build validation passed for the iPhone Duo iOS 27.2 simulator. The widget
  appeared in the system gallery, rendered live Alamein status in the small
  family, and its configuration changed to Pakenham. The medium family was
  included in the supported sizes but was not visually inspected in this pass.
