@testable import PadelFinderBackend
import Foundation
import Logging
import VaporTesting
import Testing

@Suite("App Tests")
struct PadelFinderBackendTests {
    @Test("Test Hello World Route")
    func helloWorld() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }

    @Test("Padel Hub logo asset is publicly served")
    func padelHubLogoAssetIsServed() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "logos/padel-hub.png", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.readableBytes > 0)
            })
        }
    }

    @Test("Gym Breeze logo asset is publicly served")
    func gymBreezeLogoAssetIsServed() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "logos/gym-breeze.png", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.readableBytes > 0)
            })
        }
    }

    @Test("Availability route returns selected date")
    func availabilityRouteReturnsSelectedDate() async throws {
        let service = MockAvailabilityService(companies: [sampleCompany()])

        try await withApp(configure: { app async throws in
            try routes(app, availabilityService: service)
        }) { app in
            try await app.testing().test(.GET, "availability?date=2026-05-27", afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(AvailabilityResponse.self)
                #expect(response.date == "2026-05-27")
                #expect(response.companies.count == 1)
                #expect(response.companies.first?.id == "company-a")
                #expect(response.companies.first?.logo == "https://example.com/logo.png")
                #expect(response.companies.first?.coverImage == "https://example.com/cover.jpg")
                #expect(response.companies.first?.courts.first?.id == "court-a")
            })
        }

        let requestedDates = await service.requestedDates()
        #expect(requestedDates == ["2026-05-27"])
    }

    @Test("Availability route expands backend asset paths")
    func availabilityRouteExpandsBackendAssetPaths() async throws {
        let service = MockAvailabilityService(companies: [
            sampleCompany(logo: "/logos/company.png", coverImage: "/covers/company.jpg")
        ])

        try await withApp(configure: { app async throws in
            app.publicBaseURL = "https://api.padelfinder.test"
            try routes(app, availabilityService: service)
        }) { app in
            try await app.testing().test(
                .GET,
                "availability?date=2026-05-27",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)

                    let response = try res.content.decode(AvailabilityResponse.self)
                    #expect(response.companies.first?.logo == "https://api.padelfinder.test/logos/company.png")
                    #expect(response.companies.first?.coverImage == "https://api.padelfinder.test/covers/company.jpg")
                }
            )
        }
    }

    @Test("Availability route defaults missing date to today in Tbilisi")
    func availabilityRouteDefaultsMissingDate() async throws {
        let service = MockAvailabilityService(companies: [])

        try await withApp(configure: { app async throws in
            try routes(app, availabilityService: service)
        }) { app in
            try await app.testing().test(.GET, "availability", afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(AvailabilityResponse.self)
                #expect(response.date == TbilisiDate.todayString())
            })
        }
    }

    @Test("Availability route rejects invalid date")
    func availabilityRouteRejectsInvalidDate() async throws {
        let service = MockAvailabilityService(companies: [])

        try await withApp(configure: { app async throws in
            try routes(app, availabilityService: service)
        }) { app in
            try await app.testing().test(.GET, "availability?date=2026-99-99", afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }

        let requestedDates = await service.requestedDates()
        #expect(requestedDates.isEmpty)
    }

    @Test("Company availability route returns the matching company")
    func companyAvailabilityRouteReturnsMatchingCompany() async throws {
        let service = MockAvailabilityService(companies: [
            sampleCompany(companyID: "company-a", courtID: "court-a"),
            sampleCompany(companyID: "company-b", courtID: "court-b")
        ])

        try await withApp(configure: { app async throws in
            try routes(app, availabilityService: service)
        }) { app in
            try await app.testing().test(.GET, "availability/company/company-b?date=2026-05-27", afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(CompanyAvailabilityResponse.self)
                #expect(response.date == "2026-05-27")
                #expect(response.company.id == "company-b")
                #expect(response.company.courts.first?.id == "court-b")
            })
        }

        let requestedDates = await service.requestedDates()
        #expect(requestedDates == ["2026-05-27"])
    }

    @Test("Company availability route returns 404 for unknown company")
    func companyAvailabilityRouteReturnsNotFoundForUnknownCompany() async throws {
        let service = MockAvailabilityService(companies: [sampleCompany()])

        try await withApp(configure: { app async throws in
            try routes(app, availabilityService: service)
        }) { app in
            try await app.testing().test(.GET, "availability/company/does-not-exist?date=2026-05-27", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Company availability route rejects invalid date")
    func companyAvailabilityRouteRejectsInvalidDate() async throws {
        let service = MockAvailabilityService(companies: [sampleCompany()])

        try await withApp(configure: { app async throws in
            try routes(app, availabilityService: service)
        }) { app in
            try await app.testing().test(.GET, "availability/company/company-a?date=2026-99-99", afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }

        let requestedDates = await service.requestedDates()
        #expect(requestedDates.isEmpty)
    }

    @Test("Company availability serves a fresh cache without refetching")
    func companyAvailabilityServesFreshCache() async {
        let provider = MockAvailabilityProvider(result: .success([
            sampleCompany(companyID: "company-a", courtID: "court-a"),
            sampleCompany(companyID: "company-b", courtID: "court-b")
        ]))
        let dateProvider = TestDateProvider(Date(timeIntervalSince1970: 0))
        let service = AvailabilityService(
            providers: [provider],
            cache: AvailabilityCache(ttlSeconds: 120),
            dateProvider: dateProvider
        )

        // First call populates the whole-day cache from the provider.
        _ = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))
        // Second call (per-company) must reuse the cache, not refetch.
        let company = await service.companyAvailability(forCompany: "company-b", date: "2026-05-27", logger: Logger(label: "test"))

        #expect(company?.id == "company-b")
        #expect(company?.courts.first?.id == "court-b")

        let fetchCount = await provider.fetchCount()
        #expect(fetchCount == 1)
    }

    @Test("Tbilisi Padel mapper fills omitted unavailable slots")
    func tbilisiPadelMapperMapsSlots() throws {
        let json = """
        {
          "working_details": {
            "2026-05-27": [
              {
                "start_time": "10:00",
                "is_booked": 1,
                "disable_flag_timeslot": true,
                "max_capacity": 0
              },
              {
                "start_time": "09:00",
                "is_booked": 0,
                "disable_flag_timeslot": false,
                "max_capacity": "1"
              },
              {
                "start_time": "23:00",
                "end_time": "00:00",
                "is_booked": 0,
                "disable_flag_timeslot": false,
                "max_capacity": "1"
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let court = TbilisiPadelCourt.defaultCourts[0]
        let availability = try TbilisiPadelMapper.map(data: json, date: "2026-05-27", court: court)

        #expect(availability.timeSlots.map(\.time) == [
            "09:00",
            "10:00",
            "11:00",
            "12:00",
            "13:00",
            "14:00",
            "15:00",
            "16:00",
            "17:00",
            "18:00",
            "19:00",
            "20:00",
            "21:00",
            "22:00",
            "23:00"
        ])
        #expect(availability.timeSlots[0] == TimeSlot(time: "09:00", status: .available, isBookable: true))
        #expect(availability.timeSlots[1] == TimeSlot(time: "10:00", status: .booked, isBookable: false))
        #expect(availability.timeSlots[2] == TimeSlot(time: "11:00", status: .booked, isBookable: false))
        #expect(availability.timeSlots[14] == TimeSlot(time: "23:00", status: .available, isBookable: true))
    }

    @Test("Padel Island mapper maps free, booked, and half-hour slots")
    func padelIslandMapperMapsSlots() throws {
        let json = """
        {
          "d": {
            "Id": 8,
            "Nombre": "EXPO Park Tbilisi",
            "PartesPorHora": 2,
            "StrHoraInicio": "09:00",
            "StrHoraFin": "11:00",
            "StrFechaHoraInicioReservas": "27/05/2026 08:00",
            "StrFechaHoraFinReservas": "27/05/2026 23:00",
            "Columnas": [
              {
                "Id": "26",
                "TextoPrincipal": "EXPO Park No Roof",
                "TextoSecundario": "-",
                "CombinaHorariosFijosYLibres": false,
                "HorariosFijos": [],
                "Ocupaciones": [
                  {
                    "StrHoraInicio": "09:30",
                    "StrHoraFin": "10:00",
                    "Clickable": true
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let courts = try PadelIslandMapper.map(data: json, date: "2026-05-27")

        #expect(courts.count == 1)
        #expect(courts[0].id == "padel-island-8-26")
        #expect(courts[0].name == "EXPO Park No Roof")
        #expect(courts[0].timeSlots == [
            TimeSlot(time: "09:00", status: .available, isBookable: true),
            TimeSlot(time: "09:30", status: .booked, isBookable: false),
            TimeSlot(time: "10:00", status: .available, isBookable: true),
            TimeSlot(time: "10:30", status: .available, isBookable: true)
        ])
    }

    @Test("Padel Island mapper keeps overnight slot ordering")
    func padelIslandMapperKeepsOvernightOrdering() throws {
        let json = """
        {
          "d": {
            "Id": 8,
            "Nombre": "EXPO Park Tbilisi",
            "PartesPorHora": 2,
            "StrHoraInicio": "23:00",
            "StrHoraFin": "01:00",
            "StrFechaHoraInicioReservas": "27/05/2026 08:00",
            "StrFechaHoraFinReservas": "28/05/2026 02:00",
            "Columnas": [
              {
                "Id": "27",
                "TextoPrincipal": "EXPO Park Roof",
                "TextoSecundario": "-",
                "CombinaHorariosFijosYLibres": false,
                "HorariosFijos": [],
                "Ocupaciones": []
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let courts = try PadelIslandMapper.map(data: json, date: "2026-05-27")

        #expect(courts.first?.timeSlots.map(\.time) == ["23:00", "23:30", "00:00", "00:30"])
        #expect(courts.first?.timeSlots.allSatisfy(\.isBookable) == true)
    }

    @Test("Lemans mapper derives per-court availability")
    func lemansMapperDerivesPerCourtAvailability() throws {
        let courtsJSON = """
        {
          "courts": [
            {
              "id": 1,
              "court_number": 1,
              "name": "კორტი #1",
              "photo": "https://booking.lemanspadel.ge/uploads/courts/court-1.png",
              "display_order": 1,
              "duration_prices": { "60": 70 }
            },
            {
              "id": 2,
              "court_number": 2,
              "name": "კორტი #2",
              "photo": "https://booking.lemanspadel.ge/uploads/courts/court-2.png",
              "display_order": 2,
              "duration_prices": { "60": 70 }
            }
          ]
        }
        """.data(using: .utf8)!

        let availabilityJSON = """
        {
          "date": "2026-05-27",
          "duration": 60,
          "slots": [
            {
              "start": "09:00",
              "end": "10:00",
              "available": true,
              "available_courts": 1
            },
            {
              "start": "10:00",
              "end": "11:00",
              "available": false,
              "available_courts": 0
            },
            {
              "start": "23:00",
              "end": "00:00",
              "available": true,
              "available_courts": 2
            }
          ]
        }
        """.data(using: .utf8)!

        let courts = try JSONDecoder().decode(LemansCourtsResponse.self, from: courtsJSON).courts
        let slots = try JSONDecoder().decode(LemansAvailabilityResponse.self, from: availabilityJSON).slots
        let availability = LemansPadelMapper.map(
            courts: courts,
            slots: slots,
            availableCourtsBySlot: [
                "09:00": [1],
                "23:00": [1, 2]
            ]
        )

        #expect(availability.count == 2)
        #expect(availability[0].id == "lemans-padel-1")
        #expect(availability[0].name == "კორტი #1")
        #expect(availability[0].pricePerHour == 70)
        #expect(availability[0].timeSlots == [
            TimeSlot(time: "09:00", status: .available, isBookable: true),
            TimeSlot(time: "10:00", status: .booked, isBookable: false),
            TimeSlot(time: "23:00", status: .available, isBookable: true)
        ])
        #expect(availability[1].timeSlots == [
            TimeSlot(time: "09:00", status: .booked, isBookable: false),
            TimeSlot(time: "10:00", status: .booked, isBookable: false),
            TimeSlot(time: "23:00", status: .available, isBookable: true)
        ])
    }

    @Test("Lemans mapper marks today's past slots booked")
    func lemansMapperMarksTodayPastSlotsBooked() throws {
        let courtsJSON = """
        {
          "courts": [
            {
              "id": 1,
              "court_number": 1,
              "name": "კორტი #1",
              "display_order": 1,
              "duration_prices": { "60": 70 }
            }
          ]
        }
        """.data(using: .utf8)!

        let courts = try JSONDecoder().decode(LemansCourtsResponse.self, from: courtsJSON).courts
        let now = try #require(LemansPadelDate.slotDate(selectedDate: "2026-05-27", time: "18:00"))
        let availability = LemansPadelMapper.map(
            courts: courts,
            slots: [
                LemansAvailabilitySlot(start: "13:00", end: "14:00", available: true, availableCourts: 1),
                LemansAvailabilitySlot(start: "19:00", end: "20:00", available: true, availableCourts: 1)
            ],
            availableCourtsBySlot: [
                "13:00": [1],
                "19:00": [1]
            ],
            selectedDate: "2026-05-27",
            now: now
        )

        #expect(availability.first?.timeSlots == [
            TimeSlot(time: "13:00", status: .booked, isBookable: false),
            TimeSlot(time: "19:00", status: .available, isBookable: true)
        ])
    }

    @Test("Kustba mapper derives court availability from slot and court statuses")
    func kustbaMapperDerivesCourtAvailability() throws {
        let slotsJSON = """
        {
          "success": true,
          "data": [
            {
              "time": "10:00",
              "status": "inactive"
            },
            {
              "time": "11:00",
              "status": "available"
            },
            {
              "time": "12:00",
              "status": "available"
            }
          ]
        }
        """.data(using: .utf8)!

        let courtsAt10JSON = """
        {
          "courts": [
            {
              "id": 25406,
              "title": "Court 1",
              "price": 80,
              "court_number": 1,
              "image": "https://via.placeholder.com/300x200?text=Padel+Court",
              "status": "active",
              "reason": ""
            },
            {
              "id": 25407,
              "title": "Court 2",
              "price": 80,
              "court_number": 2,
              "image": "https://kustbapadel.ge/court-2.png",
              "status": "active",
              "reason": ""
            }
          ]
        }
        """.data(using: .utf8)!

        let courtsAt11JSON = """
        {
          "courts": [
            {
              "id": 25406,
              "title": "Court 1",
              "price": 80,
              "court_number": 1,
              "image": "https://via.placeholder.com/300x200?text=Padel+Court",
              "status": "active",
              "reason": ""
            },
            {
              "id": 25407,
              "title": "Court 2",
              "price": 80,
              "court_number": 2,
              "image": "https://kustbapadel.ge/court-2.png",
              "status": "inactive",
              "reason": "booked"
            }
          ]
        }
        """.data(using: .utf8)!

        let courtsAt12JSON = """
        {
          "courts": [
            {
              "id": 25406,
              "title": "Court 1",
              "price": 80,
              "court_number": 1,
              "image": "https://via.placeholder.com/300x200?text=Padel+Court",
              "status": "active",
              "reason": ""
            },
            {
              "id": 25407,
              "title": "Court 2",
              "price": 80,
              "court_number": 2,
              "image": "https://kustbapadel.ge/court-2.png",
              "status": "active",
              "reason": ""
            }
          ]
        }
        """.data(using: .utf8)!

        let slots = try JSONDecoder().decode(KustbaAJAXResponse<[KustbaSlot]>.self, from: slotsJSON).data
        let courtsAt10 = try JSONDecoder().decode(KustbaCourtsData.self, from: courtsAt10JSON).courts
        let courtsAt11 = try JSONDecoder().decode(KustbaCourtsData.self, from: courtsAt11JSON).courts
        let courtsAt12 = try JSONDecoder().decode(KustbaCourtsData.self, from: courtsAt12JSON).courts

        let courts = KustbaPadelMapper.map(
            slots: slots,
            courtsBySlot: [
                "10:00": courtsAt10,
                "11:00": courtsAt11,
                "12:00": courtsAt12
            ],
            address: "Kus Tba, Tbilisi"
        )

        #expect(courts.count == 2)
        #expect(courts[0].id == "kustba-padel-25406")
        #expect(courts[0].name == "Court 1")
        #expect(courts[0].pricePerHour == 80)
        #expect(courts[0].address == "Kus Tba, Tbilisi")
        #expect(courts[0].timeSlots == [
            TimeSlot(time: "10:00", status: .booked, isBookable: false),
            TimeSlot(time: "11:00", status: .available, isBookable: true),
            TimeSlot(time: "12:00", status: .available, isBookable: true)
        ])
        #expect(courts[1].timeSlots == [
            TimeSlot(time: "10:00", status: .booked, isBookable: false),
            TimeSlot(time: "11:00", status: .booked, isBookable: false),
            TimeSlot(time: "12:00", status: .available, isBookable: true)
        ])
    }

    @Test("Kustba date resolver shifts overnight slots to the next booking date")
    func kustbaDateResolverShiftsOvernightSlots() {
        #expect(KustbaBookingDateResolver.bookingDate(for: "2026-06-17", time: "23:00", startHour: 9) == "2026-06-17")
        #expect(KustbaBookingDateResolver.bookingDate(for: "2026-06-17", time: "00:00", startHour: 9) == "2026-06-18")
        #expect(KustbaBookingDateResolver.bookingDate(for: "2026-02-28", time: "01:00", startHour: 9) == "2026-03-01")
    }

    @Test("Padel Gldani parser extracts WooCommerce booking block times")
    func padelGldaniParserExtractsBookingBlockTimes() {
        let html = """
        <div class="wc-bookings-start-time-container" data-product-id="72">
          <select id="wc-bookings-form-start-time" name="start_time">
            <option value="0">დაწყება</option>
            <option data-block="0800" value="2026-06-20T08:00:00+0300">08:00</option>
            <option data-block="2300" value="2026-06-20T23:00:00+0300">23:00</option>
            <option data-block="0000" value="2026-06-21T00:00:00+0300">00:00</option>
          </select>
        </div>
        """

        #expect(PadelGldaniBlocksParser.availableTimes(from: html) == ["00:00", "08:00", "23:00"])
    }

    @Test("Padel Gldani mapper builds business-day slots from same and next day availability")
    func padelGldaniMapperBuildsBusinessDaySlots() {
        let availableTimes = PadelGldaniMapper.businessDayAvailableTimes(
            sameDayTimes: ["00:00", "08:00", "23:00"],
            nextDayTimes: ["00:00", "01:00", "08:00"],
            startHour: 8
        )

        let courts = PadelGldaniMapper.map(
            courts: [PadelGldaniCourt(productID: 72, name: "Court I", displayOrder: 1)],
            availableTimesByProductID: [72: availableTimes],
            date: "2026-06-19",
            address: "56 Ilia Vekua St"
        )

        #expect(courts.count == 1)
        #expect(courts[0].id == "padel-gldani-72")
        #expect(courts[0].name == "Court I")
        #expect(courts[0].address == "56 Ilia Vekua St")
        #expect(courts[0].pricePerHour == 50)
        #expect(courts[0].timeSlots.map(\.time) == [
            "08:00",
            "09:00",
            "10:00",
            "11:00",
            "12:00",
            "13:00",
            "14:00",
            "15:00",
            "16:00",
            "17:00",
            "18:00",
            "19:00",
            "20:00",
            "21:00",
            "22:00",
            "23:00",
            "00:00",
            "01:00"
        ])
        #expect(courts[0].timeSlots[0] == TimeSlot(time: "08:00", status: .available, isBookable: true))
        #expect(courts[0].timeSlots[1] == TimeSlot(time: "09:00", status: .booked, isBookable: false))
        #expect(courts[0].timeSlots[15] == TimeSlot(time: "23:00", status: .available, isBookable: true))
        #expect(courts[0].timeSlots[16] == TimeSlot(time: "00:00", status: .available, isBookable: true))
        #expect(courts[0].timeSlots[17] == TimeSlot(time: "01:00", status: .available, isBookable: true))
    }

    @Test("Padel Gldani weekend price is 60 GEL")
    func padelGldaniWeekendPrice() {
        #expect(PadelGldaniDate.pricePerHour(for: "2026-06-20") == 60)
    }

    @Test("Padel Hub mapper splits court availability by price window")
    func padelHubMapperSplitsCourtAvailabilityByPriceWindow() throws {
        let now = try #require(PadelHubDate.slotDate(selectedDate: "2026-06-20", time: "09:30"))
        let courts = [
            PadelHubCourt(
                id: "0a0a2ddd-4f0d-4a66-a5c3-2d08bcf5eebd",
                name: "court_padel_open",
                description: "court_padel_open_desc",
                sportType: "padel",
                imageURL: "/courts/padel-open.jpg",
                isActive: true,
                createdAt: "2026-05-14T04:15:12.07446+00:00"
            )
        ]

        let availability = PadelHubMapper.map(
            courts: courts,
            unavailableBookingsByCourtID: [
                "0a0a2ddd-4f0d-4a66-a5c3-2d08bcf5eebd": [
                    PadelHubBookingAvailability(timeSlot: "10:00", bookingDate: "2026-06-20", status: "confirmed"),
                    PadelHubBookingAvailability(timeSlot: "11:00", bookingDate: "2026-06-20", status: "cancelled"),
                    PadelHubBookingAvailability(timeSlot: "13:00", bookingDate: "2026-06-20", status: "cancelled")
                ]
            ],
            selectedDate: "2026-06-20",
            address: "39 Petre Kavtaradze St, Tbilisi",
            now: now
        )

        #expect(availability.count == 2)
        #expect(availability[0].id == "padel-hub-0a0a2ddd-4f0d-4a66-a5c3-2d08bcf5eebd-08-15")
        #expect(availability[0].name == "Open Padel Court 08:00 - 15:00")
        #expect(availability[0].address == "39 Petre Kavtaradze St, Tbilisi")
        #expect(availability[0].pricePerHour == 40)
        #expect(availability[0].timeSlots.map(\.time) == [
            "08:00",
            "09:00",
            "10:00",
            "11:00",
            "12:00",
            "13:00",
            "14:00"
        ])
        #expect(availability[0].timeSlots[0] == TimeSlot(time: "08:00", status: .booked, isBookable: false))
        #expect(availability[0].timeSlots[1] == TimeSlot(time: "09:00", status: .booked, isBookable: false))
        #expect(availability[0].timeSlots[2] == TimeSlot(time: "10:00", status: .booked, isBookable: false))
        #expect(availability[0].timeSlots[3] == TimeSlot(time: "11:00", status: .booked, isBookable: false))
        #expect(availability[0].timeSlots[5] == TimeSlot(time: "13:00", status: .available, isBookable: true))

        #expect(availability[1].id == "padel-hub-0a0a2ddd-4f0d-4a66-a5c3-2d08bcf5eebd-15-00")
        #expect(availability[1].name == "Open Padel Court 15:00 - 01:00")
        #expect(availability[1].address == "39 Petre Kavtaradze St, Tbilisi")
        #expect(availability[1].pricePerHour == 60)
        #expect(availability[1].timeSlots.map(\.time) == [
            "15:00",
            "16:00",
            "17:00",
            "18:00",
            "19:00",
            "20:00",
            "21:00",
            "22:00",
            "23:00",
            "00:00"
        ])
        #expect(availability[1].timeSlots[9] == TimeSlot(time: "00:00", status: .available, isBookable: true))
    }

    @Test("Gym Breeze mapper builds location availability by price window")
    func gymBreezeMapperBuildsLocationAvailabilityByPriceWindow() {
        let ninoshviliID = "ninoshvili"
        let radioCityID = "radio-city"
        let locations = [
            GymBreezeLocation(
                id: ninoshviliID,
                workingHours: [
                    GymBreezeWorkingHour(
                        dayOfWeek: 4,
                        dayName: "Friday",
                        openTime: "08:00:00",
                        closeTime: "01:00:00",
                        isClosed: false
                    )
                ],
                pricingRules: [
                    GymBreezePricingRule(
                        id: nil,
                        dayOfWeek: 4,
                        startHour: "08:00:00",
                        endHour: "11:00:00",
                        hourlyRate: "60.00",
                        isActive: true
                    ),
                    GymBreezePricingRule(
                        id: nil,
                        dayOfWeek: 4,
                        startHour: "11:00:00",
                        endHour: "18:00:00",
                        hourlyRate: "40.00",
                        isActive: true
                    ),
                    GymBreezePricingRule(
                        id: nil,
                        dayOfWeek: 4,
                        startHour: "18:00:00",
                        endHour: "01:00:00",
                        hourlyRate: "60.00",
                        isActive: true
                    )
                ],
                specialPrices: [],
                name: GymBreezeLocalizedText(en: "Ninoshvili Street", ka: nil),
                address: GymBreezeLocalizedText(en: "Egnate Ninoshvili #64, Tbilisi, Georgia", ka: nil),
                isActive: true
            ),
            GymBreezeLocation(
                id: radioCityID,
                workingHours: [
                    GymBreezeWorkingHour(
                        dayOfWeek: 4,
                        dayName: "Friday",
                        openTime: "08:00:00",
                        closeTime: "01:00:00",
                        isClosed: false
                    )
                ],
                pricingRules: [
                    GymBreezePricingRule(
                        id: nil,
                        dayOfWeek: 4,
                        startHour: "08:00:00",
                        endHour: "01:00:00",
                        hourlyRate: "30.00",
                        isActive: true
                    )
                ],
                specialPrices: [],
                name: GymBreezeLocalizedText(en: "Radio City", ka: nil),
                address: GymBreezeLocalizedText(en: "Barbare Bairamashvili, #3, TBILISI, GEORGIA", ka: nil),
                isActive: true
            )
        ]
        let ninoshviliCourts: [GymBreezeCourt] = (1...8).map { (courtNumber: Int) -> GymBreezeCourt in
            GymBreezeCourt(
                id: "ninoshvili-court-\(courtNumber)",
                sportTypeName: GymBreezeLocalizedText(en: "Padel", ka: nil),
                locationName: GymBreezeLocalizedText(en: "Ninoshvili Street", ka: nil),
                number: courtNumber,
                displayName: GymBreezeLocalizedText(en: "Court \(courtNumber)", ka: nil),
                isActive: true,
                location: ninoshviliID,
                sportType: "00000000-0000-0000-0000-000000000000"
            )
        }
        let radioCityCourts: [GymBreezeCourt] = (1...3).map { (courtNumber: Int) -> GymBreezeCourt in
            GymBreezeCourt(
                id: "radio-city-court-\(courtNumber)",
                sportTypeName: GymBreezeLocalizedText(en: "Padel", ka: nil),
                locationName: GymBreezeLocalizedText(en: "Radio City", ka: nil),
                number: courtNumber,
                displayName: GymBreezeLocalizedText(en: "Court \(courtNumber)", ka: nil),
                isActive: true,
                location: radioCityID,
                sportType: "00000000-0000-0000-0000-000000000000"
            )
        }
        let availability = GymBreezeMapper.map(
            locations: locations,
            courtsByLocationID: [
                ninoshviliID: ninoshviliCourts,
                radioCityID: radioCityCourts
            ],
            availabilityByLocationID: [
                ninoshviliID: GymBreezeAvailabilityResponse(
                    locationID: ninoshviliID,
                    date: "2026-06-19",
                    availableSlots: [
                        GymBreezeAvailableSlot(start: "2026-06-19T08:00:00+04:00", end: "2026-06-19T09:00:00+04:00"),
                        GymBreezeAvailableSlot(start: "2026-06-19T10:00:00+04:00", end: "2026-06-19T11:00:00+04:00"),
                        GymBreezeAvailableSlot(start: "2026-06-19T11:00:00+04:00", end: "2026-06-19T12:00:00+04:00"),
                        GymBreezeAvailableSlot(start: "2026-06-19T17:00:00+04:00", end: "2026-06-19T18:00:00+04:00"),
                        GymBreezeAvailableSlot(start: "2026-06-19T18:00:00+04:00", end: "2026-06-19T19:00:00+04:00"),
                        GymBreezeAvailableSlot(start: "2026-06-20T00:00:00+04:00", end: "2026-06-20T01:00:00+04:00")
                    ]
                ),
                radioCityID: GymBreezeAvailabilityResponse(
                    locationID: radioCityID,
                    date: "2026-06-19",
                    availableSlots: [
                        GymBreezeAvailableSlot(start: "2026-06-19T08:00:00+04:00", end: "2026-06-19T09:00:00+04:00"),
                        GymBreezeAvailableSlot(start: "2026-06-20T00:00:00+04:00", end: "2026-06-20T01:00:00+04:00")
                    ]
                )
            ],
            selectedDate: "2026-06-19",
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(availability.count == 4)

        #expect(availability[0].name == "Ninoshvili Street 08:00 - 11:00")
        #expect(availability[0].address == "Egnate Ninoshvili #64, Tbilisi, Georgia")
        #expect(availability[0].pricePerHour == 60)
        #expect(availability[0].totalCourts == 8)
        #expect(availability[0].timeSlots == [
            TimeSlot(time: "08:00", status: .available, isBookable: true),
            TimeSlot(time: "09:00", status: .booked, isBookable: false),
            TimeSlot(time: "10:00", status: .available, isBookable: true)
        ])

        #expect(availability[1].name == "Ninoshvili Street 11:00 - 18:00")
        #expect(availability[1].pricePerHour == 40)
        #expect(availability[1].timeSlots.first == TimeSlot(time: "11:00", status: .available, isBookable: true))
        #expect(availability[1].timeSlots.last == TimeSlot(time: "17:00", status: .available, isBookable: true))

        #expect(availability[2].name == "Ninoshvili Street 18:00 - 01:00")
        #expect(availability[2].pricePerHour == 60)
        #expect(availability[2].timeSlots.map(\.time) == ["18:00", "19:00", "20:00", "21:00", "22:00", "23:00", "00:00"])
        #expect(availability[2].timeSlots[0] == TimeSlot(time: "18:00", status: .available, isBookable: true))
        #expect(availability[2].timeSlots[6] == TimeSlot(time: "00:00", status: .available, isBookable: true))

        #expect(availability[3].name == "Radio City")
        #expect(availability[3].address == "Barbare Bairamashvili, #3, TBILISI, GEORGIA")
        #expect(availability[3].pricePerHour == 30)
        #expect(availability[3].totalCourts == 3)
        #expect(availability[3].timeSlots.first == TimeSlot(time: "08:00", status: .available, isBookable: true))
        #expect(availability[3].timeSlots.last == TimeSlot(time: "00:00", status: .available, isBookable: true))
    }

    @Test("Fresh cache avoids provider fetch")
    func freshCacheAvoidsProviderFetch() async {
        let provider = MockAvailabilityProvider(result: .success([sampleCompany(courtID: "court-a")]))
        let dateProvider = TestDateProvider(Date(timeIntervalSince1970: 0))
        let service = AvailabilityService(
            providers: [provider],
            cache: AvailabilityCache(ttlSeconds: 120),
            dateProvider: dateProvider
        )

        let first = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))
        await provider.setResult(.success([sampleCompany(courtID: "court-b")]))
        let second = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))

        #expect(first.companies.first?.courts.first?.id == "court-a")
        #expect(second.companies.first?.courts.first?.id == "court-a")

        let fetchCount = await provider.fetchCount()
        #expect(fetchCount == 1)
    }

    @Test("Expired cache refreshes provider data")
    func expiredCacheRefreshesProviderData() async {
        let provider = MockAvailabilityProvider(result: .success([sampleCompany(courtID: "court-a")]))
        let dateProvider = TestDateProvider(Date(timeIntervalSince1970: 0))
        let service = AvailabilityService(
            providers: [provider],
            cache: AvailabilityCache(ttlSeconds: 120),
            dateProvider: dateProvider
        )

        _ = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))
        await provider.setResult(.success([sampleCompany(courtID: "court-b")]))
        await dateProvider.set(Date(timeIntervalSince1970: 121))
        let refreshed = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))

        #expect(refreshed.companies.first?.courts.first?.id == "court-b")

        let fetchCount = await provider.fetchCount()
        #expect(fetchCount == 2)
    }

    @Test("Provider failure after cache expiry returns empty companies")
    func providerFailureAfterCacheExpiryReturnsEmptyCompanies() async {
        let provider = MockAvailabilityProvider(result: .success([sampleCompany(courtID: "court-a")]))
        let dateProvider = TestDateProvider(Date(timeIntervalSince1970: 0))
        let service = AvailabilityService(
            providers: [provider],
            cache: AvailabilityCache(ttlSeconds: 120),
            dateProvider: dateProvider
        )

        _ = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))
        await provider.setResult(.failure)
        await dateProvider.set(Date(timeIntervalSince1970: 121))
        let failedRefresh = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))

        #expect(failedRefresh.companies.isEmpty)

        let fetchCount = await provider.fetchCount()
        #expect(fetchCount == 2)
    }

    @Test("Warm Kus Tba cache serves requests without hitting the provider")
    func warmKustbaCacheServesWithoutProviderFetch() async {
        let store = KustbaAvailabilityStore()
        let provider = MockAvailabilityProvider(result: .success([sampleCompany(courtID: "court-a")]))
        let dateProvider = TestDateProvider(Date(timeIntervalSince1970: 0))
        let refresher = KustbaRefreshService(
            provider: provider,
            store: store,
            configuration: .init(nearDaysAhead: 0, farDaysAhead: 0, nearInterval: 60, farInterval: 1800),
            dateProvider: dateProvider
        )

        await refresher.refreshOnce(logger: Logger(label: "test"))
        let refreshCount = await provider.fetchCount()

        let cached = CachedKustbaProvider(underlying: provider, store: store, dateProvider: dateProvider)
        let today = TbilisiDate.todayString(now: Date(timeIntervalSince1970: 0))
        let companies = try? await cached.fetchAvailability(on: today, logger: Logger(label: "test"))

        #expect(companies?.first?.courts.first?.id == "court-a")

        // The read was served from the warm store, so no extra upstream fetch.
        let afterReadCount = await provider.fetchCount()
        #expect(afterReadCount == refreshCount)
    }

    @Test("Kus Tba cache miss falls back to a single coalesced fetch")
    func kustbaCacheMissCoalescesConcurrentFetches() async {
        let store = KustbaAvailabilityStore()
        let provider = MockAvailabilityProvider(result: .success([sampleCompany(courtID: "court-a")]))
        let dateProvider = TestDateProvider(Date(timeIntervalSince1970: 0))
        let cached = CachedKustbaProvider(underlying: provider, store: store, dateProvider: dateProvider)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try? await cached.fetchAvailability(on: "2026-05-27", logger: Logger(label: "test"))
                }
            }
        }

        // Five simultaneous misses must share one upstream fetch, not stampede.
        let fetchCount = await provider.fetchCount()
        #expect(fetchCount == 1)

        // And the result is cached for subsequent reads.
        _ = try? await cached.fetchAvailability(on: "2026-05-27", logger: Logger(label: "test"))
        let afterCachedRead = await provider.fetchCount()
        #expect(afterCachedRead == 1)
    }

    @Test("Kus Tba refresh keeps stale data when the provider fails")
    func kustbaRefreshKeepsStaleDataOnFailure() async {
        let store = KustbaAvailabilityStore()
        let provider = MockAvailabilityProvider(result: .success([sampleCompany(courtID: "court-a")]))
        let dateProvider = TestDateProvider(Date(timeIntervalSince1970: 0))
        let refresher = KustbaRefreshService(
            provider: provider,
            store: store,
            configuration: .init(nearDaysAhead: 0, farDaysAhead: 0, nearInterval: 60, farInterval: 1800),
            dateProvider: dateProvider
        )

        await refresher.refreshOnce(logger: Logger(label: "test"))
        await provider.setResult(.failure)

        // Advance past the near-tier interval so the date is due again.
        await dateProvider.set(Date(timeIntervalSince1970: 61))
        await refresher.refreshOnce(logger: Logger(label: "test"))

        let today = TbilisiDate.todayString(now: Date(timeIntervalSince1970: 0))
        let cachedCompanies = await store.cachedValue(for: today, now: Date(timeIntervalSince1970: 0))

        // A failed refresh must not blank out the venue.
        #expect(cachedCompanies?.first?.courts.first?.id == "court-a")
    }

    @Test("Kus Tba refresh drops past days and keeps recently requested ones")
    func kustbaRefreshTargetsPruneStaleDates() async {
        let store = KustbaAvailabilityStore()
        let now = Date(timeIntervalSince1970: 0)

        await store.store([sampleCompany()], for: "2020-01-01", now: now)
        await store.store([sampleCompany()], for: "2026-05-30", now: now)
        _ = await store.cachedValue(for: "2026-05-30", now: now)

        // Nothing is due yet: every stored date was just refreshed, and only the
        // unseen window day needs fetching.
        let due = await store.datesDueForRefresh(
            nearDates: ["2026-05-27"],
            farDates: ["2026-05-28"],
            nearInterval: 300,
            farInterval: 1800,
            today: "2026-05-27",
            now: now,
            idleTimeout: 1800
        )
        #expect(due == ["2026-05-27", "2026-05-28"])

        // Past dates are dropped entirely.
        let prunedPast = await store.cachedValue(for: "2020-01-01", now: now)
        #expect(prunedPast == nil)

        // The recently requested out-of-window date is kept, on the far cadence.
        let stillWarm = await store.cachedValue(for: "2026-05-30", now: now)
        #expect(stillWarm != nil)

        // An out-of-window date idle past the timeout stops being refreshed.
        let laterDue = await store.datesDueForRefresh(
            nearDates: ["2026-05-27"],
            farDates: [],
            nearInterval: 300,
            farInterval: 1800,
            today: "2026-05-27",
            now: now.addingTimeInterval(3600),
            idleTimeout: 1800
        )
        #expect(laterDue == ["2026-05-27"])
    }

    @Test("Kus Tba near days refresh more often than far days")
    func kustbaNearDaysRefreshMoreOftenThanFarDays() async {
        let store = KustbaAvailabilityStore()
        let now = Date(timeIntervalSince1970: 0)

        await store.store([sampleCompany()], for: "2026-05-27", now: now)
        await store.store([sampleCompany()], for: "2026-05-29", now: now)

        // 6 minutes on: the near day is due at 5 min, the far day is not (30 min).
        let due = await store.datesDueForRefresh(
            nearDates: ["2026-05-27"],
            farDates: ["2026-05-29"],
            nearInterval: 300,
            farInterval: 1800,
            today: "2026-05-27",
            now: now.addingTimeInterval(360),
            idleTimeout: 1800
        )
        #expect(due == ["2026-05-27"])

        // 31 minutes on: both tiers are due.
        let laterDue = await store.datesDueForRefresh(
            nearDates: ["2026-05-27"],
            farDates: ["2026-05-29"],
            nearInterval: 300,
            farInterval: 1800,
            today: "2026-05-27",
            now: now.addingTimeInterval(1860),
            idleTimeout: 1800
        )
        #expect(laterDue == ["2026-05-27", "2026-05-29"])
    }

    @Test("Kus Tba tiers split the warm window into near and far days")
    func kustbaTiersSplitWarmWindow() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let configuration = KustbaRefreshService.Configuration(nearDaysAhead: 1, farDaysAhead: 6)
        let tiers = configuration.tiers(now: now)

        #expect(tiers.near == ["2026-05-29", "2026-05-30"])
        #expect(tiers.far == ["2026-05-31", "2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04"])
    }

    @Test("Tbilisi date window covers today plus the requested days")
    func tbilisiDateWindowCoversRequestedDays() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let today = TbilisiDate.todayString(now: now)

        #expect(TbilisiDate.upcomingDateStrings(daysAhead: 0, now: now) == [today])
        #expect(TbilisiDate.upcomingDateStrings(daysAhead: 2, now: now).count == 3)
        #expect(TbilisiDate.upcomingDateStrings(daysAhead: 2, now: now).first == today)
        #expect(TbilisiDate.upcomingDateStrings(daysAhead: 2, now: now) == ["2026-05-29", "2026-05-30", "2026-05-31"])
    }
}

private enum MockProviderResult: Sendable {
    case success([PadelCompanyAvailability])
    case failure
}

private enum MockProviderError: Error {
    case failed
}

private actor MockAvailabilityProvider: AvailabilityProvider {
    nonisolated let id = "mock-provider"

    private var result: MockProviderResult
    private var count = 0

    init(result: MockProviderResult) {
        self.result = result
    }

    func fetchAvailability(on date: String, logger: Logger) async throws -> [PadelCompanyAvailability] {
        count += 1

        switch result {
        case .success(let companies):
            return companies
        case .failure:
            throw MockProviderError.failed
        }
    }

    func setResult(_ result: MockProviderResult) {
        self.result = result
    }

    func fetchCount() -> Int {
        count
    }
}

private actor MockAvailabilityService: AvailabilityServiceProtocol {
    private let companies: [PadelCompanyAvailability]
    private var dates: [String]

    init(companies: [PadelCompanyAvailability]) {
        self.companies = companies
        self.dates = []
    }

    func availability(for date: String, logger: Logger) async -> AvailabilityResponse {
        dates.append(date)
        return AvailabilityResponse(date: date, companies: companies)
    }

    func companyAvailability(forCompany companyId: String, date: String, logger: Logger) async -> PadelCompanyAvailability? {
        dates.append(date)
        return companies.first { $0.id == companyId }
    }

    func requestedDates() -> [String] {
        dates
    }
}

private actor TestDateProvider: DateProviding {
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() async -> Date {
        current
    }

    func set(_ date: Date) {
        current = date
    }
}

private func sampleCompany(
    companyID: String = "company-a",
    courtID: String = "court-a",
    logo: String? = "https://example.com/logo.png",
    coverImage: String? = "https://example.com/cover.jpg"
) -> PadelCompanyAvailability {
    PadelCompanyAvailability(
        id: companyID,
        name: "Padel Company",
        website: "https://example.com",
        logo: logo,
        coverImage: coverImage,
        courts: [sampleCourt(id: courtID)]
    )
}

private func sampleCourt(id: String = "court-a") -> CourtAvailability {
    CourtAvailability(
        id: id,
        name: "Padel Club Vake",
        address: "123 Rustaveli Ave",
        pricePerHour: 60,
        rating: 4.8,
        totalCourts: 6,
        timeSlots: [
            TimeSlot(time: "09:00", status: .available, isBookable: true)
        ]
    )
}
