import Foundation

private func dateIsBeforeToday(_ date: Date) -> Bool {
    let cal = Calendar.current
    return cal.startOfDay(for: date) < cal.startOfDay(for: Date())
}

enum Gender: String, LenientEnum, CaseIterable, Hashable {
    case male = "Male"
    case female = "Female"
    case other = "Other"
    case preferNotToSay = "preferNotToSay"
    static let fallback: Gender = .preferNotToSay
}

struct Address: Codable, Hashable, Sendable {
    var street: String
    var city: String
    var postalCode: String
    var region: String
    var country: String

    init(street: String = "", city: String = "", postalCode: String = "", region: String = "", country: String = "") {
        self.street = street
        self.city = city
        self.postalCode = postalCode
        self.region = region
        self.country = country
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        street = decodeLossyString(c, forKey: .street) ?? ""
        city = decodeLossyString(c, forKey: .city) ?? ""
        postalCode = decodeLossyString(c, forKey: .postalCode) ?? ""
        region = decodeLossyString(c, forKey: .region) ?? ""
        country = decodeLossyString(c, forKey: .country) ?? ""
    }
}

struct EmergencyContact: Codable, Hashable, Sendable {
    var name: String
    var phone: String
    var relationship: String
    var email: String?

    init(name: String = "", phone: String = "", relationship: String = "", email: String? = nil) {
        self.name = name
        self.phone = phone
        self.relationship = relationship
        self.email = email
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = decodeLossyString(c, forKey: .name) ?? ""
        phone = decodeLossyString(c, forKey: .phone) ?? ""
        relationship = decodeLossyString(c, forKey: .relationship) ?? ""
        email = decodeLossyString(c, forKey: .email)
    }
}

extension EmergencyContact {
    /// Nothing entered: the editor stores `nil` rather than an empty contact.
    var isEmpty: Bool {
        name.isEmpty && phone.isEmpty && relationship.isEmpty && (email ?? "").isEmpty
    }
}

struct InsuranceInfo: Codable, Hashable, Sendable {
    var provider: String
    var policyNumber: String
    var groupNumber: String?
    var validUntil: Date?

    init(provider: String = "", policyNumber: String = "", groupNumber: String? = nil, validUntil: Date? = nil) {
        self.provider = provider
        self.policyNumber = policyNumber
        self.groupNumber = groupNumber
        self.validUntil = validUntil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = decodeLossyString(c, forKey: .provider) ?? ""
        policyNumber = decodeLossyString(c, forKey: .policyNumber) ?? ""
        groupNumber = decodeLossyString(c, forKey: .groupNumber)
        validUntil = try? c.decodeIfPresent(Date.self, forKey: .validUntil)
    }
}

extension InsuranceInfo {
    /// Nothing entered: the editor stores `nil` rather than an empty policy.
    var isEmpty: Bool {
        provider.isEmpty && policyNumber.isEmpty && (groupNumber ?? "").isEmpty && validUntil == nil
    }
}

struct PatientProfile: Codable, Hashable, Sendable {
    var firstName: String
    var lastName: String
    var fathersName: String?
    var dateOfBirth: Date
    var gender: Gender
    var amka: String
    var afm: String?
    var idNumber: String?
    var phone: String
    var email: String
    var address: Address
    var emergencyContact: EmergencyContact?
    var insurance: InsuranceInfo?
    var photo: Data?

    var fullName: String {
        [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Epoch-0 is the missing-DOB sentinel. Real dates before 1970 must still count.
    var hasKnownDateOfBirth: Bool {
        abs(dateOfBirth.timeIntervalSince1970) > 0.001
    }

    var age: Int {
        let cal = Calendar(identifier: .gregorian)
        return cal.dateComponents([.year], from: dateOfBirth, to: Date()).year ?? 0
    }

    init(firstName: String = "", lastName: String = "", fathersName: String? = nil,
         dateOfBirth: Date, gender: Gender = .preferNotToSay, amka: String = "",
         afm: String? = nil, idNumber: String? = nil, phone: String = "", email: String = "",
         address: Address = Address(), emergencyContact: EmergencyContact? = nil,
         insurance: InsuranceInfo? = nil, photo: Data? = nil) {
        self.firstName = firstName
        self.lastName = lastName
        self.fathersName = fathersName
        self.dateOfBirth = dateOfBirth
        self.gender = gender
        self.amka = amka
        self.afm = afm
        self.idNumber = idNumber
        self.phone = phone
        self.email = email
        self.address = address
        self.emergencyContact = emergencyContact
        self.insurance = insurance
        self.photo = photo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstName = decodeLossyString(c, forKey: .firstName) ?? ""
        lastName = decodeLossyString(c, forKey: .lastName) ?? ""
        fathersName = decodeLossyString(c, forKey: .fathersName)
        dateOfBirth = (try? c.decodeIfPresent(Date.self, forKey: .dateOfBirth))
            ?? Date(timeIntervalSince1970: 0)
        gender = (try? c.decodeIfPresent(Gender.self, forKey: .gender)) ?? .preferNotToSay
        amka = decodeLossyString(c, forKey: .amka) ?? ""
        afm = decodeLossyString(c, forKey: .afm)
        idNumber = decodeLossyString(c, forKey: .idNumber)
        phone = decodeLossyString(c, forKey: .phone) ?? ""
        email = decodeLossyString(c, forKey: .email) ?? ""
        address = (try? c.decodeIfPresent(Address.self, forKey: .address)) ?? Address()
        emergencyContact = try? c.decodeIfPresent(EmergencyContact.self, forKey: .emergencyContact)
        insurance = try? c.decodeIfPresent(InsuranceInfo.self, forKey: .insurance)
        photo = try? c.decodeIfPresent(Data.self, forKey: .photo)
    }
}

enum BloodType: String, LenientEnum, CaseIterable, Hashable {
    case aPositive = "aPositive"
    case aNegative = "aNegative"
    case bPositive = "bPositive"
    case bNegative = "bNegative"
    case abPositive = "abPositive"
    case abNegative = "abNegative"
    case oPositive = "oPositive"
    case oNegative = "oNegative"
    case unknown = "unknown"
    static let fallback: BloodType = .unknown

    static func parse(_ raw: String) -> BloodType {
        if let exact = Self(rawValue: raw) { return exact }
        switch raw.replacingOccurrences(of: " ", with: "").uppercased() {
        case "A+": return .aPositive
        case "A-": return .aNegative
        case "B+": return .bPositive
        case "B-": return .bNegative
        case "AB+": return .abPositive
        case "AB-": return .abNegative
        case "O+": return .oPositive
        case "O-": return .oNegative
        default:
            for c in Self.allCases where Self.normalize(c.rawValue) == Self.normalize(raw) { return c }
            return fallback
        }
    }
}

enum MedicationRoute: String, LenientEnum, CaseIterable, Hashable {
    case oral = "Oral"
    case intravenous = "Intravenous"
    case intramuscular = "Intramuscular"
    case subcutaneous = "Subcutaneous"
    case topical = "Topical"
    case inhalation = "Inhalation"
    case nasal = "Nasal"
    case otic = "Otic"
    case ophthalmic = "Ophthalmic"
    case rectal = "Rectal"
    case sublingual = "Sublingual"
    case transdermal = "Transdermal"
    static let fallback: MedicationRoute = .oral
}

enum AllergySeverity: String, LenientEnum, CaseIterable, Hashable {
    case mild = "Mild"
    case moderate = "Moderate"
    case severe = "Severe"
    case lifeThreatening = "lifeThreatening"
    static let fallback: AllergySeverity = .moderate
}

struct Allergy: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var allergen: String
    var severity: AllergySeverity
    var reaction: String
    var notes: String

    init(id: UUID = UUID(), allergen: String = "", severity: AllergySeverity = .moderate,
         reaction: String = "", notes: String = "") {
        self.id = id
        self.allergen = allergen
        self.severity = severity
        self.reaction = reaction
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = decodeLossyUUID(c, forKey: .id) ?? UUID()
        allergen = decodeLossyString(c, forKey: .allergen) ?? ""
        severity = (try? c.decodeIfPresent(AllergySeverity.self, forKey: .severity)) ?? .moderate
        reaction = decodeLossyString(c, forKey: .reaction) ?? ""
        notes = decodeLossyString(c, forKey: .notes) ?? ""
    }
}

enum ConditionStatus: String, LenientEnum, CaseIterable, Hashable {
    case active = "Active"
    case chronic = "chronic"
    case inactive = "Inactive"
    case discontinued = "Discontinued"
    case resolved = "Resolved"
    static let fallback: ConditionStatus = .active
}

struct MedicalCondition: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var status: ConditionStatus
    var diagnosedDate: Date?
    var notes: String

    init(id: UUID = UUID(), name: String = "", status: ConditionStatus = .active,
         diagnosedDate: Date? = nil, notes: String = "") {
        self.id = id
        self.name = name
        self.status = status
        self.diagnosedDate = diagnosedDate
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = decodeLossyUUID(c, forKey: .id) ?? UUID()
        name = decodeLossyString(c, forKey: .name) ?? ""
        status = (try? c.decodeIfPresent(ConditionStatus.self, forKey: .status)) ?? .active
        diagnosedDate = try? c.decodeIfPresent(Date.self, forKey: .diagnosedDate)
        notes = decodeLossyString(c, forKey: .notes) ?? ""
    }
}

struct Medication: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var dosage: String
    var frequency: String
    var startDate: Date
    var endDate: Date?
    var prescribedBy: String
    var notes: String
    var isActive: Bool
    var reasonForStopping: String?

    var isCurrentlyActive: Bool {
        guard isActive else { return false }
        if let end = endDate, dateIsBeforeToday(end) { return false }
        let cal = Calendar.current
        if cal.startOfDay(for: startDate) > cal.startOfDay(for: Date()) { return false }
        return true
    }

    init(id: UUID = UUID(), name: String = "", dosage: String = "", frequency: String = "",
         startDate: Date = Date(), endDate: Date? = nil, prescribedBy: String = "",
         notes: String = "", isActive: Bool = true, reasonForStopping: String? = nil) {
        self.id = id
        self.name = name
        self.dosage = dosage
        self.frequency = frequency
        self.startDate = startDate
        self.endDate = endDate
        self.prescribedBy = prescribedBy
        self.notes = notes
        self.isActive = isActive
        self.reasonForStopping = reasonForStopping
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = decodeLossyUUID(c, forKey: .id) ?? UUID()
        name = decodeLossyString(c, forKey: .name) ?? ""
        dosage = decodeLossyString(c, forKey: .dosage) ?? ""
        frequency = decodeLossyString(c, forKey: .frequency) ?? ""
        startDate = (try? c.decodeIfPresent(Date.self, forKey: .startDate)) ?? Date()
        endDate = try? c.decodeIfPresent(Date.self, forKey: .endDate)
        prescribedBy = decodeLossyString(c, forKey: .prescribedBy) ?? ""
        notes = decodeLossyString(c, forKey: .notes) ?? ""
        isActive = decodeLossyBool(c, forKey: .isActive) ?? true
        if let end = endDate, dateIsBeforeToday(end) {
            isActive = false
        }
        reasonForStopping = decodeLossyString(c, forKey: .reasonForStopping)
    }
}

extension Medication {
    /// Records the regimen as ended on `date`; the reason is optional.
    mutating func stop(on date: Date = Date(), reason: String? = nil) {
        isActive = false
        endDate = date
        reasonForStopping = reason
    }

    /// Back on the regimen: the end date and reason no longer apply.
    mutating func resume() {
        isActive = true
        endDate = nil
        reasonForStopping = nil
    }
}

struct VitalSignsRecord: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var recordedAt: Date
    var recordedBy: String
    var heartRate: Int?
    var bloodPressure: String?
    var systolicBP: Int?
    var diastolicBP: Int?
    var temperature: Double?
    var temperatureFahrenheit: Double?
    var respiratoryRate: Int?
    var oxygenSaturation: Int?
    var glucoseLevel: Int?
    var painLevel: Int?
    var weight: Double?
    var notes: String

    init(id: UUID = UUID(), recordedAt: Date = Date(), recordedBy: String = "",
         heartRate: Int? = nil, bloodPressure: String? = nil, systolicBP: Int? = nil,
         diastolicBP: Int? = nil, temperature: Double? = nil, temperatureFahrenheit: Double? = nil,
         respiratoryRate: Int? = nil, oxygenSaturation: Int? = nil, glucoseLevel: Int? = nil,
         painLevel: Int? = nil, weight: Double? = nil, notes: String = "") {
        self.id = id
        self.recordedAt = recordedAt
        self.recordedBy = recordedBy
        self.heartRate = heartRate
        self.bloodPressure = bloodPressure
        self.systolicBP = systolicBP
        self.diastolicBP = diastolicBP
        self.temperature = temperature
        self.temperatureFahrenheit = temperatureFahrenheit
        self.respiratoryRate = respiratoryRate
        self.oxygenSaturation = oxygenSaturation
        self.glucoseLevel = glucoseLevel
        self.painLevel = painLevel
        self.weight = weight
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = decodeLossyUUID(c, forKey: .id) ?? UUID()
        recordedAt = (try? c.decodeIfPresent(Date.self, forKey: .recordedAt)) ?? Date()
        recordedBy = decodeLossyString(c, forKey: .recordedBy) ?? ""
        heartRate = decodeLossyInt(c, forKey: .heartRate)
        bloodPressure = decodeLossyString(c, forKey: .bloodPressure)
        systolicBP = decodeLossyInt(c, forKey: .systolicBP)
        diastolicBP = decodeLossyInt(c, forKey: .diastolicBP)
        temperature = decodeLossyDouble(c, forKey: .temperature)
        temperatureFahrenheit = decodeLossyDouble(c, forKey: .temperatureFahrenheit)
        respiratoryRate = decodeLossyInt(c, forKey: .respiratoryRate)
        oxygenSaturation = decodeLossyInt(c, forKey: .oxygenSaturation)
        glucoseLevel = decodeLossyInt(c, forKey: .glucoseLevel)
        painLevel = decodeLossyInt(c, forKey: .painLevel)
        weight = decodeLossyDouble(c, forKey: .weight)
        notes = decodeLossyString(c, forKey: .notes) ?? ""
    }
}

struct MedicalProcedure: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var date: Date
    var performedBy: String
    var assistants: [String]
    var duration: Double
    var outcome: String
    var complications: String?
    var notes: String
    var cptCode: String?

    init(id: UUID = UUID(), name: String = "", date: Date = Date(), performedBy: String = "",
         assistants: [String] = [], duration: Double = 0, outcome: String = "",
         complications: String? = nil, notes: String = "", cptCode: String? = nil) {
        self.id = id
        self.name = name
        self.date = date
        self.performedBy = performedBy
        self.assistants = assistants
        self.duration = duration
        self.outcome = outcome
        self.complications = complications
        self.notes = notes
        self.cptCode = cptCode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = decodeLossyUUID(c, forKey: .id) ?? UUID()
        name = decodeLossyString(c, forKey: .name) ?? ""
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
        performedBy = decodeLossyString(c, forKey: .performedBy) ?? ""
        assistants = decodeLossyStrings(c, forKey: .assistants)
        duration = decodeLossyDouble(c, forKey: .duration) ?? 0
        outcome = decodeLossyString(c, forKey: .outcome) ?? ""
        complications = decodeLossyString(c, forKey: .complications)
        notes = decodeLossyString(c, forKey: .notes) ?? ""
        cptCode = decodeLossyString(c, forKey: .cptCode)
    }
}

struct HospitalMedication: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var medicationName: String
    var dosage: String
    var frequency: String
    var route: MedicationRoute
    var startDate: Date
    var endDate: Date?
    var prescribedBy: String
    var administeredBy: [String]
    var indication: String
    var notes: String
    var sideEffects: [String]
    var isActive: Bool
    var discontinued: Bool
    var discontinuationReason: String?

    init(id: UUID = UUID(), medicationName: String = "", dosage: String = "", frequency: String = "",
         route: MedicationRoute = .oral, startDate: Date = Date(), endDate: Date? = nil,
         prescribedBy: String = "", administeredBy: [String] = [], indication: String = "",
         notes: String = "", sideEffects: [String] = [], isActive: Bool = true,
         discontinued: Bool = false, discontinuationReason: String? = nil) {
        self.id = id
        self.medicationName = medicationName
        self.dosage = dosage
        self.frequency = frequency
        self.route = route
        self.startDate = startDate
        self.endDate = endDate
        self.prescribedBy = prescribedBy
        self.administeredBy = administeredBy
        self.indication = indication
        self.notes = notes
        self.sideEffects = sideEffects
        self.isActive = isActive
        self.discontinued = discontinued
        self.discontinuationReason = discontinuationReason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = decodeLossyUUID(c, forKey: .id) ?? UUID()
        medicationName = decodeLossyString(c, forKey: .medicationName) ?? ""
        dosage = decodeLossyString(c, forKey: .dosage) ?? ""
        frequency = decodeLossyString(c, forKey: .frequency) ?? ""
        route = (try? c.decodeIfPresent(MedicationRoute.self, forKey: .route)) ?? .oral
        startDate = (try? c.decodeIfPresent(Date.self, forKey: .startDate)) ?? Date()
        endDate = try? c.decodeIfPresent(Date.self, forKey: .endDate)
        prescribedBy = decodeLossyString(c, forKey: .prescribedBy) ?? ""
        administeredBy = decodeLossyStrings(c, forKey: .administeredBy)
        indication = decodeLossyString(c, forKey: .indication) ?? ""
        notes = decodeLossyString(c, forKey: .notes) ?? ""
        sideEffects = decodeLossyStrings(c, forKey: .sideEffects)
        isActive = decodeLossyBool(c, forKey: .isActive) ?? true
        discontinued = decodeLossyBool(c, forKey: .discontinued) ?? false
        if discontinued {
            isActive = false
        }
        if let end = endDate, dateIsBeforeToday(end) {
            isActive = false
            discontinued = true
        }
        discontinuationReason = decodeLossyString(c, forKey: .discontinuationReason)
    }
}

enum AdmissionType: String, LenientEnum, CaseIterable, Hashable {
    case elective = "Elective"
    case emergency = "Emergency"
    case urgent = "Urgent"
    case transfer = "Transfer"
    case maternity = "Maternity"
    case daycare = "daycare"
    case rehabilitation = "rehabilitation"
    case psychiatric = "psychiatric"
    case traumaLevel = "traumaLevel"
    static let fallback: AdmissionType = .elective
}

enum DischargeType: String, LenientEnum, CaseIterable, Hashable {
    case home = "home"
    case homeWithServices = "homeWithServices"
    case hospice = "hospice"
    case transferAcute = "transferAcute"
    case transferNursing = "transferNursing"
    case transferRehab = "transferRehab"
    case transferPsych = "transferPsych"
    case leftWithoutDischarge = "leftWithoutDischarge"
    static let fallback: DischargeType = .home
}

enum UrgencyLevel: String, LenientEnum, CaseIterable, Hashable {
    case routine = "Routine"
    case urgent = "Urgent"
    case emergent = "Emergent"
    static let fallback: UrgencyLevel = .routine
}

enum HospitalizationStatus: String, LenientEnum, CaseIterable, Hashable {
    case admitted = "Admitted"
    case discharged = "Discharged"
    case inTransfer = "inTransfer"
    static let fallback: HospitalizationStatus = .admitted
}

struct Hospitalization: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var admissionDate: Date
    var admissionReason: String
    var admissionType: AdmissionType
    var hospitalName: String
    var hospitalAddress: String
    var department: String
    var ward: String?
    var roomNumber: String?
    var attendingPhysician: String
    var consultingPhysicians: [String]
    var primaryDiagnosis: String
    var secondaryDiagnoses: [String]
    var procedures: [MedicalProcedure]
    var medicationsAdministered: [HospitalMedication]
    var labResults: [String]
    var vitalsHistory: [VitalSignsRecord]
    var treatmentPlan: String
    var notes: String
    var dischargeDate: Date?
    var dischargeType: DischargeType?
    var dischargeSummary: String
    var dischargeInstructions: String
    var followUpRequired: Bool
    var followUpDate: Date?
    var followUpPhysician: String?
    var insuranceProvider: String?
    var insuranceAuthorizationNumber: String?
    var emergencyContact: String?
    var emergencyContactPhone: String?
    var estimatedCost: Double?
    var actualCost: Double?
    var attachments: [String]
    var status: HospitalizationStatus
    var urgencyLevel: UrgencyLevel
    var isActive: Bool
    var createdAt: Date
    var lastModified: Date

    var lengthOfStay: Int? {
        guard let d = dischargeDate else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day],
            from: cal.startOfDay(for: admissionDate),
            to: cal.startOfDay(for: d)).day
    }

    var isCurrentlyAdmitted: Bool { dischargeDate == nil && status != .discharged }

    init(id: UUID = UUID(), admissionDate: Date = Date(), admissionReason: String = "",
         admissionType: AdmissionType = .elective, hospitalName: String = "",
         hospitalAddress: String = "", department: String = "", ward: String? = nil,
         roomNumber: String? = nil, attendingPhysician: String = "",
         consultingPhysicians: [String] = [], primaryDiagnosis: String = "",
         secondaryDiagnoses: [String] = [], procedures: [MedicalProcedure] = [],
         medicationsAdministered: [HospitalMedication] = [], labResults: [String] = [],
         vitalsHistory: [VitalSignsRecord] = [], treatmentPlan: String = "", notes: String = "",
         dischargeDate: Date? = nil, dischargeType: DischargeType? = nil,
         dischargeSummary: String = "", dischargeInstructions: String = "",
         followUpRequired: Bool = false, followUpDate: Date? = nil,
         followUpPhysician: String? = nil, insuranceProvider: String? = nil,
         insuranceAuthorizationNumber: String? = nil, emergencyContact: String? = nil,
         emergencyContactPhone: String? = nil, estimatedCost: Double? = nil,
         actualCost: Double? = nil, attachments: [String] = [],
         status: HospitalizationStatus = .admitted, urgencyLevel: UrgencyLevel = .routine,
         isActive: Bool = true, createdAt: Date = Date(), lastModified: Date = Date()) {
        self.id = id
        self.admissionDate = admissionDate
        self.admissionReason = admissionReason
        self.admissionType = admissionType
        self.hospitalName = hospitalName
        self.hospitalAddress = hospitalAddress
        self.department = department
        self.ward = ward
        self.roomNumber = roomNumber
        self.attendingPhysician = attendingPhysician
        self.consultingPhysicians = consultingPhysicians
        self.primaryDiagnosis = primaryDiagnosis
        self.secondaryDiagnoses = secondaryDiagnoses
        self.procedures = procedures
        self.medicationsAdministered = medicationsAdministered
        self.labResults = labResults
        self.vitalsHistory = vitalsHistory
        self.treatmentPlan = treatmentPlan
        self.notes = notes
        self.dischargeDate = dischargeDate
        self.dischargeType = dischargeType
        self.dischargeSummary = dischargeSummary
        self.dischargeInstructions = dischargeInstructions
        self.followUpRequired = followUpRequired
        self.followUpDate = followUpDate
        self.followUpPhysician = followUpPhysician
        self.insuranceProvider = insuranceProvider
        self.insuranceAuthorizationNumber = insuranceAuthorizationNumber
        self.emergencyContact = emergencyContact
        self.emergencyContactPhone = emergencyContactPhone
        self.estimatedCost = estimatedCost
        self.actualCost = actualCost
        self.attachments = attachments
        self.status = status
        self.urgencyLevel = urgencyLevel
        self.isActive = isActive
        self.createdAt = createdAt
        self.lastModified = lastModified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = decodeLossyUUID(c, forKey: .id) ?? UUID()
        admissionDate = (try? c.decodeIfPresent(Date.self, forKey: .admissionDate)) ?? Date()
        admissionReason = decodeLossyString(c, forKey: .admissionReason) ?? ""
        admissionType = (try? c.decodeIfPresent(AdmissionType.self, forKey: .admissionType)) ?? .elective
        hospitalName = decodeLossyString(c, forKey: .hospitalName) ?? ""
        hospitalAddress = decodeLossyString(c, forKey: .hospitalAddress) ?? ""
        department = decodeLossyString(c, forKey: .department) ?? ""
        ward = decodeLossyString(c, forKey: .ward)
        roomNumber = decodeLossyString(c, forKey: .roomNumber)
        attendingPhysician = decodeLossyString(c, forKey: .attendingPhysician) ?? ""
        consultingPhysicians = decodeLossyStrings(c, forKey: .consultingPhysicians)
        primaryDiagnosis = decodeLossyString(c, forKey: .primaryDiagnosis) ?? ""
        secondaryDiagnoses = decodeLossyStrings(c, forKey: .secondaryDiagnoses)
        procedures = decodeLossyArray(MedicalProcedure.self, c, forKey: .procedures)
        medicationsAdministered = decodeLossyArray(HospitalMedication.self, c, forKey: .medicationsAdministered)
        labResults = decodeLossyStrings(c, forKey: .labResults)
        vitalsHistory = decodeLossyArray(VitalSignsRecord.self, c, forKey: .vitalsHistory)
        treatmentPlan = decodeLossyString(c, forKey: .treatmentPlan) ?? ""
        notes = decodeLossyString(c, forKey: .notes) ?? ""
        dischargeDate = try? c.decodeIfPresent(Date.self, forKey: .dischargeDate)
        dischargeType = try? c.decodeIfPresent(DischargeType.self, forKey: .dischargeType)
        dischargeSummary = decodeLossyString(c, forKey: .dischargeSummary) ?? ""
        dischargeInstructions = decodeLossyString(c, forKey: .dischargeInstructions) ?? ""
        followUpRequired = decodeLossyBool(c, forKey: .followUpRequired) ?? false
        followUpDate = try? c.decodeIfPresent(Date.self, forKey: .followUpDate)
        followUpPhysician = decodeLossyString(c, forKey: .followUpPhysician)
        insuranceProvider = decodeLossyString(c, forKey: .insuranceProvider)
        insuranceAuthorizationNumber = decodeLossyString(c, forKey: .insuranceAuthorizationNumber)
        emergencyContact = decodeLossyString(c, forKey: .emergencyContact)
        emergencyContactPhone = decodeLossyString(c, forKey: .emergencyContactPhone)
        estimatedCost = decodeLossyDouble(c, forKey: .estimatedCost)
        actualCost = decodeLossyDouble(c, forKey: .actualCost)
        attachments = decodeLossyStrings(c, forKey: .attachments)
        status = (try? c.decodeIfPresent(HospitalizationStatus.self, forKey: .status)) ?? .admitted
        urgencyLevel = (try? c.decodeIfPresent(UrgencyLevel.self, forKey: .urgencyLevel)) ?? .routine
        isActive = decodeLossyBool(c, forKey: .isActive) ?? true
        if dischargeDate != nil || status == .discharged {
            isActive = false
            if status == .admitted {
                status = .discharged
            }
        }
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        lastModified = (try? c.decodeIfPresent(Date.self, forKey: .lastModified)) ?? createdAt
    }
}

enum VisitType: String, LenientEnum, CaseIterable, Hashable {
    case checkup = "checkup"
    case consultation = "consultation"
    case surgery = "Surgery"
    case labTest = "labTest"
    case labResult = "labResult"
    case prescription = "prescription"
    case vaccine = "Vaccine"
    case observation = "observation"
    case emergency = "Emergency"
    case other = "other"
    static let fallback: VisitType = .other
}

enum VisitStatus: String, LenientEnum, CaseIterable, Hashable {
    case scheduled = "Scheduled"
    case completed = "Completed"
    case noShow = "noShow"
    case cancelled = "Cancelled"
    static let fallback: VisitStatus = .scheduled
}

struct Visit: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var date: Date
    var type: VisitType
    var status: VisitStatus
    var chiefComplaint: String
    var diagnosis: String
    var treatment: String
    var notes: String
    var followUpRequired: Bool
    var followUpDate: Date?
    var attachments: [String]

    init(id: UUID = UUID(), date: Date = Date(), type: VisitType = .checkup,
         status: VisitStatus = .completed, chiefComplaint: String = "", diagnosis: String = "",
         treatment: String = "", notes: String = "", followUpRequired: Bool = false,
         followUpDate: Date? = nil, attachments: [String] = []) {
        self.id = id
        self.date = date
        self.type = type
        self.status = status
        self.chiefComplaint = chiefComplaint
        self.diagnosis = diagnosis
        self.treatment = treatment
        self.notes = notes
        self.followUpRequired = followUpRequired
        self.followUpDate = followUpDate
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = decodeLossyUUID(c, forKey: .id) ?? UUID()
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
        type = (try? c.decodeIfPresent(VisitType.self, forKey: .type)) ?? .checkup
        status = (try? c.decodeIfPresent(VisitStatus.self, forKey: .status)) ?? .completed
        chiefComplaint = decodeLossyString(c, forKey: .chiefComplaint) ?? ""
        diagnosis = decodeLossyString(c, forKey: .diagnosis) ?? ""
        treatment = decodeLossyString(c, forKey: .treatment) ?? ""
        notes = decodeLossyString(c, forKey: .notes) ?? ""
        followUpRequired = decodeLossyBool(c, forKey: .followUpRequired) ?? false
        followUpDate = try? c.decodeIfPresent(Date.self, forKey: .followUpDate)
        attachments = decodeLossyStrings(c, forKey: .attachments)
    }
}

struct Appointment: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var date: Date
    var duration: Double
    var type: VisitType
    var patientId: UUID
    var notes: String
    var isConfirmed: Bool
    var reminderSet: Bool

    init(id: UUID = UUID(), date: Date = Date(), duration: Double = 1800,
         type: VisitType = .checkup, patientId: UUID = UUID(), notes: String = "",
         isConfirmed: Bool = false, reminderSet: Bool = false) {
        self.id = id
        self.date = date
        self.duration = duration
        self.type = type
        self.patientId = patientId
        self.notes = notes
        self.isConfirmed = isConfirmed
        self.reminderSet = reminderSet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = decodeLossyUUID(c, forKey: .id) ?? UUID()
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
        duration = decodeLossyDouble(c, forKey: .duration) ?? 1800
        type = (try? c.decodeIfPresent(VisitType.self, forKey: .type)) ?? .checkup
        patientId = decodeLossyUUID(c, forKey: .patientId) ?? UUID()
        notes = decodeLossyString(c, forKey: .notes) ?? ""
        isConfirmed = decodeLossyBool(c, forKey: .isConfirmed) ?? false
        reminderSet = decodeLossyBool(c, forKey: .reminderSet) ?? false
    }
}

enum AlertType: String, LenientEnum, CaseIterable, Hashable {
    case medication = "medication"
    case appointment = "Appointment"
    case checkup = "checkup"
    case labTest = "labTest"
    case vaccine = "vaccine"
    case other = "other"
    static let fallback: AlertType = .other
}

enum AlertPriority: String, LenientEnum, CaseIterable, Hashable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"
    static let fallback: AlertPriority = .medium
}

struct MedicalAlert: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var message: String
    var type: AlertType
    var priority: AlertPriority
    var dueDate: Date
    var isCompleted: Bool
    var completedDate: Date?

    init(id: UUID = UUID(), title: String = "", message: String = "", type: AlertType = .other,
         priority: AlertPriority = .medium, dueDate: Date = Date(), isCompleted: Bool = false,
         completedDate: Date? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.type = type
        self.priority = priority
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.completedDate = completedDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = decodeLossyUUID(c, forKey: .id) ?? UUID()
        title = decodeLossyString(c, forKey: .title) ?? ""
        message = decodeLossyString(c, forKey: .message) ?? ""
        type = (try? c.decodeIfPresent(AlertType.self, forKey: .type)) ?? .other
        priority = (try? c.decodeIfPresent(AlertPriority.self, forKey: .priority)) ?? .medium
        dueDate = (try? c.decodeIfPresent(Date.self, forKey: .dueDate)) ?? Date()
        isCompleted = decodeLossyBool(c, forKey: .isCompleted) ?? false
        completedDate = try? c.decodeIfPresent(Date.self, forKey: .completedDate)
        if !isCompleted {
            completedDate = nil
        }
    }
}

enum TagColor: String, LenientEnum, CaseIterable, Hashable {
    case red = "Red"
    case blue = "Blue"
    case green = "Green"
    case yellow = "Yellow"
    case purple = "Purple"
    case orange = "Orange"
    case pink = "Pink"
    case cyan = "Cyan"
    case indigo = "Indigo"
    case gray = "Gray"
    static let fallback: TagColor = .gray
}

enum TagCategory: String, LenientEnum, CaseIterable, Hashable {
    case general = "General"
    case medical = "medical"
    case personal = "personal"
    case behavioral = "behavioral"
    case chronic = "chronic"
    case treatmentPriority = "Treatment Priority"
    static let fallback: TagCategory = .general
}

struct PatientTag: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var color: TagColor
    var category: TagCategory
    var notes: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String = "", color: TagColor = .gray,
         category: TagCategory = .general, notes: String = "", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.color = color
        self.category = category
        self.notes = notes
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = decodeLossyUUID(c, forKey: .id) ?? UUID()
        name = decodeLossyString(c, forKey: .name) ?? ""
        color = (try? c.decodeIfPresent(TagColor.self, forKey: .color)) ?? .gray
        category = (try? c.decodeIfPresent(TagCategory.self, forKey: .category)) ?? .general
        notes = decodeLossyString(c, forKey: .notes) ?? ""
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
    }
}

enum PatientFileType: String, LenientEnum, CaseIterable, Hashable {
    case pdf = "pdf"
    case image = "image"
    case document = "document"
    case labResult = "labResult"
    case xray = "xray"
    case photo = "photo"
    case other = "other"
    static let fallback: PatientFileType = .other
}

struct PatientFile: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var type: PatientFileType
    var data: Data?
    var fileSize: Int
    var uploadDate: Date
    var notes: String
    var tags: [String]
    /// Opaque storage identifier inside `EncryptedFileStore`. Never derived
    /// from the patient, the file name or the path.
    var storageID: String?
    /// The decrypted byte count, recorded so the UI and backups never have to
    /// decrypt to know a size.
    var plaintextLength: Int?
    /// BLAKE2b digest of the plaintext, verified after backup restore.
    var contentDigest: String?

    init(id: UUID = UUID(), name: String = "", type: PatientFileType = .other,
         data: Data? = nil, fileSize: Int = 0, uploadDate: Date = Date(), notes: String = "",
         tags: [String] = [], storageID: String? = nil, plaintextLength: Int? = nil,
         contentDigest: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.data = data
        self.fileSize = fileSize
        self.uploadDate = uploadDate
        self.notes = notes
        self.tags = tags
        self.storageID = storageID
        self.plaintextLength = plaintextLength
        self.contentDigest = contentDigest
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = decodeLossyUUID(c, forKey: .id) ?? UUID()
        name = decodeLossyString(c, forKey: .name) ?? ""
        type = (try? c.decodeIfPresent(PatientFileType.self, forKey: .type)) ?? .other
        data = try? c.decodeIfPresent(Data.self, forKey: .data)
        uploadDate = (try? c.decodeIfPresent(Date.self, forKey: .uploadDate)) ?? Date()
        notes = decodeLossyString(c, forKey: .notes) ?? ""
        tags = decodeLossyStrings(c, forKey: .tags)
        storageID = decodeLossyString(c, forKey: .storageID)
        plaintextLength = decodeLossyInt(c, forKey: .plaintextLength)
        contentDigest = decodeLossyString(c, forKey: .contentDigest)
        if let size = decodeLossyInt(c, forKey: .fileSize) {
            fileSize = size
        } else {
            fileSize = data?.count ?? plaintextLength ?? 0
        }
    }
}

struct MedicalInfo: Codable, Hashable, Sendable {
    var conditions: [MedicalCondition]
    var allergies: [Allergy]
    var medications: [Medication]
    var notes: String
    var bloodType: BloodType?
    var height: Double?
    var weight: Double?

    var hasActiveMedications: Bool { medications.contains(where: \.isCurrentlyActive) }

    init(conditions: [MedicalCondition] = [], allergies: [Allergy] = [],
         medications: [Medication] = [], notes: String = "", bloodType: BloodType? = nil,
         height: Double? = nil, weight: Double? = nil) {
        self.conditions = conditions
        self.allergies = allergies
        self.medications = medications
        self.notes = notes
        self.bloodType = bloodType
        self.height = height
        self.weight = weight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conditions = decodeLossyArray(MedicalCondition.self, c, forKey: .conditions)
        allergies = decodeLossyArray(Allergy.self, c, forKey: .allergies)
        medications = decodeLossyArray(Medication.self, c, forKey: .medications)
        notes = decodeLossyString(c, forKey: .notes) ?? ""
        bloodType = try? c.decodeIfPresent(BloodType.self, forKey: .bloodType)
        height = decodeLossyDouble(c, forKey: .height)
        weight = decodeLossyDouble(c, forKey: .weight)
    }
}

struct Patient: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var profile: PatientProfile
    var medical: MedicalInfo
    var tags: [PatientTag]
    var alerts: [MedicalAlert]
    var visits: [Visit]
    var upcomingAppointments: [Appointment]
    var hospitalizations: [Hospitalization]
    var files: [PatientFile]
    var notes: [String]
    var tasks: [String]
    var createdAt: Date
    var lastModified: Date
    var isArchived: Bool

    var displayName: String { profile.fullName }

    init(id: UUID = UUID(), profile: PatientProfile, medical: MedicalInfo = MedicalInfo(),
         tags: [PatientTag] = [], alerts: [MedicalAlert] = [], visits: [Visit] = [],
         upcomingAppointments: [Appointment] = [], hospitalizations: [Hospitalization] = [],
         files: [PatientFile] = [], notes: [String] = [], tasks: [String] = [],
         createdAt: Date = Date(), lastModified: Date = Date(), isArchived: Bool = false) {
        self.id = id
        self.profile = profile
        self.medical = medical
        self.tags = tags
        self.alerts = alerts
        self.visits = visits
        self.upcomingAppointments = upcomingAppointments
        self.hospitalizations = hospitalizations
        self.files = files
        self.notes = notes
        self.tasks = tasks
        self.createdAt = createdAt
        self.lastModified = lastModified
        self.isArchived = isArchived
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        profile = try c.decode(PatientProfile.self, forKey: .profile)
        medical = (try? c.decodeIfPresent(MedicalInfo.self, forKey: .medical)) ?? MedicalInfo()
        tags = decodeLossyArray(PatientTag.self, c, forKey: .tags)
        alerts = decodeLossyArray(MedicalAlert.self, c, forKey: .alerts)
        visits = decodeLossyArray(Visit.self, c, forKey: .visits)
        upcomingAppointments = decodeLossyArray(Appointment.self, c, forKey: .upcomingAppointments)
        hospitalizations = decodeLossyArray(Hospitalization.self, c, forKey: .hospitalizations)
        files = decodeLossyArray(PatientFile.self, c, forKey: .files)
        notes = decodeLossyStrings(c, forKey: .notes)
        tasks = decodeLossyStrings(c, forKey: .tasks)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        lastModified = (try? c.decodeIfPresent(Date.self, forKey: .lastModified)) ?? createdAt
        isArchived = decodeLossyBool(c, forKey: .isArchived) ?? false
    }
}
