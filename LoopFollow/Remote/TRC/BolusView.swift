// LoopFollow
// BolusView.swift

import HealthKit
import LocalAuthentication
import SwiftUI

struct BolusView: View {
    @Environment(\.presentationMode) private var presentationMode

    @State private var bolusAmount = HKQuantity(unit: .internationalUnit(), doubleValue: 0.0)
    @ObservedObject private var maxBolus = Storage.shared.maxBolus
    @ObservedObject private var bolusIncrement = Storage.shared.bolusIncrement

    @ObservedObject private var deviceRecBolus = Observable.shared.deviceRecBolus
    @ObservedObject private var enactedOrSuggested = Observable.shared.enactedOrSuggested

    @FocusState private var bolusFieldIsFocused: Bool
    @State private var showAlert = false
    @State private var alertType: AlertType? = nil
    @State private var alertMessage: String? = nil
    @State private var isLoading = false
    @State private var statusMessage: String? = nil

    private let pushNotificationManager = PushNotificationManager()
    // Bolus calculator state
    @State private var carbsForCalculation = ""
    @State private var calculatedBolusFromCarbs: Double? = nil
    @State private var isCalculatorExpanded = true
    @State private var recentCarbSuggestion: (carbs: Double, bolus: Double, minutesAgo: Int)? = nil
    @FocusState private var carbsFieldIsFocused: Bool

    enum AlertType {
        case confirmBolus
        case statusSuccess
        case statusFailure
        case validation
        case oldCalculationWarning
    }

    // MARK: - Step/precision helpers driven by stored increment

    private var stepU: Double {
        max(0.001, bolusIncrement.value.doubleValue(for: .internationalUnit()))
    }

    private var stepFractionDigits: Int {
        let inc = stepU
        if inc >= 1 { return 0 }
        var v = inc
        var digits = 0
        while digits < 6 && abs(round(v) - v) > 1e-10 {
            v *= 10; digits += 1
        }
        return min(max(digits, 0), 5)
    }

    private func roundedToStep(_ value: Double) -> Double {
        guard stepU > 0 else { return value }

        let epsilon = 1e-10
        let stepped = ((value / stepU) + epsilon).rounded(.down) * stepU

        let p = pow(10.0, Double(stepFractionDigits))
        return (stepped * p).rounded() / p
    }

    // MARK: - View

    var body: some View {
        NavigationView {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Form {
                    recommendedBlocks(now: context.date)
                    // Bolus calculator section (collapsible)
                    Section(header:
                        Button(action: {
                            withAnimation {
                                isCalculatorExpanded.toggle()
                            }
                        }) {
                            HStack {
                                Text("Bolus Calculator")
                                Spacer()
                                Image(systemName: isCalculatorExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    ) {
                        if isCalculatorExpanded {
                            HStack {
                                Text("Carbs")
                                Spacer()
                                TextField("0", text: $carbsForCalculation)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .focused($carbsFieldIsFocused)
                                    .onChange(of: carbsForCalculation) { newValue in
                                        // Only allow numbers and decimal point
                                        let filtered = newValue.filter { "0123456789.".contains($0) }
                                        // Ensure only one decimal point
                                        let components = filtered.components(separatedBy: ".")
                                        if components.count > 2 {
                                            carbsForCalculation = String(filtered.dropLast())
                                        } else {
                                            carbsForCalculation = filtered
                                        }

                                        // Calculate bolus from carbs
                                        if let carbsValue = Double(carbsForCalculation), carbsValue > 0 {
                                            calculatedBolusFromCarbs = BolusCalculatorHelper.shared.calculateBolusFromCarbs(carbsValue)
                                        } else {
                                            calculatedBolusFromCarbs = nil
                                        }
                                    }
                                Text("g")
                                    .foregroundColor(.secondary)
                            }

                            if let calculatedBolus = calculatedBolusFromCarbs {
                                Button(action: {
                                    applyCalculatedBolus()
                                }) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Calculated: \(String(format: "%.2f", calculatedBolus))U")
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                            if let carbRatio = BolusCalculatorHelper.shared.getCurrentCarbRatio() {
                                                Text("Using carb ratio: 1U per \(String(format: "%.1f", carbRatio))g")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.down.circle.fill")
                                            .foregroundColor(.blue)
                                            .font(.title2)
                                    }
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(PlainButtonStyle())
                            } else if !carbsForCalculation.isEmpty {
                                Text("Enter valid carb amount to calculate")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if BolusCalculatorHelper.shared.getCurrentCarbRatio() == nil && !carbsForCalculation.isEmpty {
                                Text("⚠️ Carb ratio not available from profile")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    Section {
                        HKQuantityInputView(
                            label: "Bolus Amount",
                            quantity: $bolusAmount,
                            unit: .internationalUnit(),
                            maxLength: 5,
                            minValue: HKQuantity(unit: .internationalUnit(), doubleValue: 0),
                            maxValue: maxBolus.value,
                            isFocused: $bolusFieldIsFocused,
                            onValidationError: { message in
                                handleValidationError(message)
                            }
                        )
                    }

                    LoadingButtonView(
                        buttonText: "Send Bolus",
                        progressText: "Sending Bolus...",
                        isLoading: isLoading,
                        action: {
                            bolusFieldIsFocused = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                let rawValue = self.bolusAmount.doubleValue(for: .internationalUnit())
                                let steppedAmount = roundedToStep(rawValue)

                                if steppedAmount > 0 {
                                    bolusAmount = HKQuantity(unit: .internationalUnit(), doubleValue: steppedAmount)
                                    alertType = .confirmBolus
                                    showAlert = true
                                }
                            }
                        },
                        isDisabled: isLoading
                    )
                }
                .navigationTitle("Bolus")
                .navigationBarTitleDisplayMode(.inline)
            }
            .onAppear {
                loadRecentCarbSuggestion()

                // Auto-populate carbs field if recent carb entry exists
                if let suggestion = recentCarbSuggestion {
                    carbsForCalculation = String(format: "%.0f", suggestion.carbs)
                    // Trigger calculation
                    if let carbsValue = Double(carbsForCalculation), carbsValue > 0 {
                        calculatedBolusFromCarbs = BolusCalculatorHelper.shared.calculateBolusFromCarbs(carbsValue)
                    }
                }
            }
            .alert(isPresented: $showAlert) {
                switch alertType {
                case .confirmBolus:
                    return Alert(
                        title: Text("Confirm Bolus"),
                        message: Text("Are you sure you want to send \(InsulinFormatter.shared.string(bolusAmount)) U?"),
                        primaryButton: .default(Text("Confirm"), action: {
                            AuthService.authenticate(reason: "Confirm your identity to send bolus.") { result in
                                if case .success = result {
                                    sendBolus()
                                }
                            }
                        }),
                        secondaryButton: .cancel()
                    )
                case .statusSuccess:
                    return Alert(
                        title: Text("Status"),
                        message: Text(statusMessage ?? ""),
                        dismissButton: .default(Text("OK"), action: {
                            presentationMode.wrappedValue.dismiss()
                        })
                    )
                case .statusFailure:
                    return Alert(
                        title: Text("Status"),
                        message: Text(statusMessage ?? ""),
                        dismissButton: .default(Text("OK"))
                    )
                case .validation:
                    return Alert(
                        title: Text("Validation Error"),
                        message: Text(alertMessage ?? "Invalid input."),
                        dismissButton: .default(Text("OK"))
                    )
                case .oldCalculationWarning:
                    return Alert(
                        title: Text("Old Calculation Warning"),
                        message: Text(alertMessage ?? ""),
                        primaryButton: .default(Text("Use Anyway")) {
                            if let rec = deviceRecBolus.value {
                                applyRecommendedBolus(rec)
                            }
                        },
                        secondaryButton: .cancel()
                    )
                case .none:
                    return Alert(title: Text("Unknown Alert"))
                }
            }
        }
    }

    // MARK: - Recommended bolus UI

    @ViewBuilder
    private func recommendedBlocks(now: Date) -> some View {
        if let rec = deviceRecBolus.value,
           let t = enactedOrSuggested.value
        {
            let ageSec = max(0, now.timeIntervalSince1970 - t)

            if ageSec < 12 * 60 {
                let maxU = maxBolus.value.doubleValue(for: .internationalUnit())
                let clamped = min(rec, maxU)
                let steppedRec = roundedToStep(clamped)

                if steppedRec > 0 {
                    let mins = Int(ageSec / 60)
                    let isStale5 = ageSec >= 5 * 60

                    Section(header: Text("Recommended Bolus")) {
                        Button {
                            handleRecommendedBolusTap(rec: steppedRec, ageSec: ageSec)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(InsulinFormatter.shared.string(steppedRec))U")
                                    Text("Calculated \(mins) minute\(mins == 1 ? "" : "s") ago")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title2)
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    Section {
                        let color: Color = isStale5 ? .red : .yellow
                        Text("WARNING: New treatments may have occurred since the last recommended bolus was calculated \(presentableMinutesFormat(timeInterval: ageSec)) ago.")
                            .font(.callout)
                            .foregroundColor(color)
                            .multilineTextAlignment(.leading)
                    }

                } else {
                    EmptyView()
                }

            } else {
                EmptyView()
            }

        } else {
            EmptyView()
        }
    }

    private func handleRecommendedBolusTap(rec: Double, ageSec: TimeInterval) {
        let isStale5 = ageSec >= 5 * 60
        let isStale12 = ageSec >= 12 * 60
        if isStale12 { return }
        if isStale5 {
            let mins = Int(ageSec / 60)
            alertMessage = "This recommended bolus was calculated \(mins) minutes ago. New treatments may have occurred since then. Proceed with caution."
            alertType = .oldCalculationWarning
            showAlert = true
        } else {
            applyRecommendedBolus(rec)
        }
    }

    private func applyRecommendedBolus(_ rec: Double) {
        let maxU = maxBolus.value.doubleValue(for: .internationalUnit())
        let clamped = min(rec, maxU)
        let stepped = roundedToStep(clamped)
        bolusAmount = HKQuantity(unit: .internationalUnit(), doubleValue: stepped)
    }

    private func presentableMinutesFormat(timeInterval: TimeInterval) -> String {
        let minutes = max(0, Int(timeInterval / 60))
        var s = "\(minutes) minute"
        if minutes == 0 || minutes > 1 { s += "s" }
        return s
    }

    // MARK: - Send

    private func sendBolus() {
        isLoading = true
        pushNotificationManager.sendBolusPushNotification(bolusAmount: bolusAmount) { success, errorMessage in
            DispatchQueue.main.async {
                isLoading = false
                if success {
                    statusMessage = "Bolus command sent successfully."
                    LogManager.shared.log(
                        category: .apns,
                        message: "sendBolusPushNotification succeeded - Bolus: \(InsulinFormatter.shared.string(bolusAmount)) U"
                    )
                    bolusAmount = HKQuantity(unit: .internationalUnit(), doubleValue: 0.0)
                    alertType = .statusSuccess
                } else {
                    statusMessage = errorMessage ?? "Failed to send bolus command."
                    LogManager.shared.log(
                        category: .apns,
                        message: "sendBolusPushNotification failed with error: \(errorMessage ?? "unknown error")"
                    )
                    alertType = .statusFailure
                }
                showAlert = true
            }
        }
    }

    private func handleValidationError(_ message: String) {
        alertMessage = message
        alertType = .validation
        showAlert = true
    }

    private func loadRecentCarbSuggestion() {
        // Load recent carb suggestion
        recentCarbSuggestion = BolusCalculatorHelper.shared.getSuggestedBolusFromRecentCarbs()
    }

    private func applyCalculatedBolus() {
        guard let calculatedBolus = calculatedBolusFromCarbs else { return }
        bolusAmount = HKQuantity(unit: .internationalUnit(), doubleValue: calculatedBolus)
        carbsFieldIsFocused = false
    }
}
