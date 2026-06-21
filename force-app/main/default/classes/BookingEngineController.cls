public with sharing class BookingEngineController {

    // ── Search available resources ───────────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static List<ResourceWrapper> searchAvailability(
        String resourceType,
        String date,
        String preferredTime,
        Integer partySize
    ) {
        Date bookingDate = Date.valueOf(date);

        // Query listings that match type and capacity
        List<Booking_Listing__c> listings = [
            SELECT Id, Name, Description__c, Resource_Type__c, Capacity__c,
                   Location__c, Base_Price__c, Price_Unit__c, Currency__c,
                   Image_URL__c, Status__c
            FROM   Booking_Listing__c
            WHERE  Resource_Type__c = :resourceType
            AND    Capacity__c     >= :partySize
            AND    Status__c        = 'Active'
            WITH   SECURITY_ENFORCED
            ORDER BY Base_Price__c ASC
            LIMIT  50
        ];

        // Collect IDs of listings already held or booked on this date
        Set<Id> unavailableIds = getUnavailableListingIds(
            new Map<Id, Booking_Listing__c>(listings).keySet(), bookingDate
        );

        List<ResourceWrapper> results = new List<ResourceWrapper>();
        for (Booking_Listing__c l : listings) {
            ResourceWrapper rw = new ResourceWrapper();
            rw.id          = l.Id;
            rw.name        = l.Name;
            rw.description = l.Description__c;
            rw.resourceType= l.Resource_Type__c;
            rw.capacity    = l.Capacity__c != null ? l.Capacity__c.intValue() : 0;
            rw.location    = l.Location__c;
            rw.basePrice   = l.Base_Price__c != null ? l.Base_Price__c : 0;
            rw.priceUnit   = l.Price_Unit__c;
            rw.currency    = l.Currency__c != null ? l.Currency__c : 'USD';
            rw.imageUrl    = l.Image_URL__c;
            rw.status      = unavailableIds.contains(l.Id) ? 'Unavailable' : 'Available';
            rw.timeSlots   = generateTimeSlots(l.Id, bookingDate, preferredTime, unavailableIds.contains(l.Id));
            results.add(rw);
        }
        return results;
    }

    private static Set<Id> getUnavailableListingIds(Set<Id> listingIds, Date bookingDate) {
        Set<Id> ids = new Set<Id>();
        for (Booking__c b : [
            SELECT Listing__c
            FROM   Booking__c
            WHERE  Listing__c IN :listingIds
            AND    Booking_Date__c = :bookingDate
            AND    Status__c NOT IN ('Cancelled', 'Expired')
            WITH   SECURITY_ENFORCED
        ]) {
            ids.add(b.Listing__c);
        }
        // Also check active holds
        for (Booking_Hold__c h : [
            SELECT Listing__c
            FROM   Booking_Hold__c
            WHERE  Listing__c IN :listingIds
            AND    Booking_Date__c = :bookingDate
            AND    Expires_At__c  >  :Datetime.now()
            WITH   SECURITY_ENFORCED
        ]) {
            ids.add(h.Listing__c);
        }
        return ids;
    }

    private static List<TimeSlotWrapper> generateTimeSlots(
        Id listingId, Date bookingDate, String preferredTime, Boolean allUnavailable
    ) {
        List<TimeSlotWrapper> slots = new List<TimeSlotWrapper>();
        Integer[] hours = new Integer[]{ 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 };

        // Occupied slot start hours from confirmed bookings
        Set<Integer> occupiedHours = new Set<Integer>();
        for (Booking__c b : [
            SELECT Start_Time__c
            FROM   Booking__c
            WHERE  Listing__c     = :listingId
            AND    Booking_Date__c = :bookingDate
            AND    Status__c NOT IN ('Cancelled', 'Expired')
            WITH   SECURITY_ENFORCED
        ]) {
            if (b.Start_Time__c != null) occupiedHours.add(b.Start_Time__c.hour());
        }

        for (Integer h : hours) {
            TimeSlotWrapper ts = new TimeSlotWrapper();
            ts.id          = listingId + '_' + h;
            ts.label       = formatHour(h) + ' – ' + formatHour(h + 1);
            ts.startHour   = h;
            ts.duration    = 1;
            ts.unavailable = allUnavailable || occupiedHours.contains(h);
            slots.add(ts);
        }
        return slots;
    }

    private static String formatHour(Integer h) {
        String ampm = h < 12 ? 'AM' : 'PM';
        Integer display = h == 0 ? 12 : (h > 12 ? h - 12 : h);
        return display + ':00 ' + ampm;
    }

    // ── Create a temporary hold ──────────────────────────────────────────────
    @AuraEnabled
    public static HoldResult createHold(Id resourceId, String slotId, Integer partySize) {
        // Release any existing hold by the same user on this listing
        releaseExistingUserHolds(resourceId);

        Booking_Hold__c hold = new Booking_Hold__c(
            Listing__c     = resourceId,
            Slot_Id__c     = slotId,
            Party_Size__c  = partySize,
            Held_By__c     = UserInfo.getUserId(),
            Expires_At__c  = Datetime.now().addMinutes(10),
            Status__c      = 'Active'
        );
        insert hold;

        HoldResult result = new HoldResult();
        result.holdId    = hold.Id;
        result.expiresAt = hold.Expires_At__c;
        return result;
    }

    private static void releaseExistingUserHolds(Id listingId) {
        List<Booking_Hold__c> existing = [
            SELECT Id FROM Booking_Hold__c
            WHERE  Listing__c  = :listingId
            AND    Held_By__c  = :UserInfo.getUserId()
            AND    Status__c   = 'Active'
            WITH   SECURITY_ENFORCED
        ];
        for (Booking_Hold__c h : existing) h.Status__c = 'Released';
        if (!existing.isEmpty()) update existing;
    }

    // ── Release a hold ───────────────────────────────────────────────────────
    @AuraEnabled
    public static void releaseHold(Id holdId) {
        Booking_Hold__c hold = [
            SELECT Id, Status__c FROM Booking_Hold__c WHERE Id = :holdId WITH SECURITY_ENFORCED
        ];
        hold.Status__c = 'Released';
        update hold;
    }

    // ── Confirmation details ─────────────────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static ConfirmationWrapper getConfirmationDetails(String reference) {
        Booking__c b = [
            SELECT Id, Name, Listing__r.Name, Start_Datetime__c, End_Datetime__c,
                   Party_Size__c, Total_Amount__c, Currency__c, Transaction_Id__c,
                   Payment_Method_Label__c, Is_Split__c, Split_Count__c, Split_Amount__c,
                   Free_Cancel_By__c, Cancellation_Penalty_Pct__c, Contact__r.Email,
                   Booking_Reference__c
            FROM   Booking__c
            WHERE  Booking_Reference__c = :reference
            WITH   SECURITY_ENFORCED
            LIMIT  1
        ];

        ConfirmationWrapper cw = new ConfirmationWrapper();
        cw.bookingId            = b.Id;
        cw.resourceName         = b.Listing__r.Name;
        cw.startDatetime        = b.Start_Datetime__c;
        cw.endDatetime          = b.End_Datetime__c;
        cw.partySize            = b.Party_Size__c != null ? b.Party_Size__c.intValue() : 0;
        cw.totalAmount          = b.Total_Amount__c;
        cw.currency             = b.Currency__c != null ? b.Currency__c : 'USD';
        cw.transactionId        = b.Transaction_Id__c;
        cw.paymentMethodLabel   = b.Payment_Method_Label__c;
        cw.isSplit              = b.Is_Split__c;
        cw.splitCount           = b.Split_Count__c != null ? b.Split_Count__c.intValue() : 1;
        cw.splitAmount          = b.Split_Amount__c;
        cw.freeCancelBy         = b.Free_Cancel_By__c;
        cw.cancellationPenalty  = b.Cancellation_Penalty_Pct__c != null ? b.Cancellation_Penalty_Pct__c.intValue() : 0;
        cw.customerEmail        = b.Contact__r?.Email;
        return cw;
    }

    // ── Invoice PDF (delegates to a Visualforce page rendered as PDF) ────────
    @AuraEnabled
    public static InvoiceResult generateInvoicePdf(String reference) {
        // Calls an internal Visualforce page and captures the PDF as base64
        PageReference pdfPage = Page.BookingInvoicePDF;
        pdfPage.getParameters().put('ref', reference);
        Blob pdfBlob = Test.isRunningTest()
            ? Blob.valueOf('PDF_PLACEHOLDER')
            : pdfPage.getContentAsPDF();

        InvoiceResult res = new InvoiceResult();
        res.base64   = EncodingUtil.base64Encode(pdfBlob);
        res.filename = 'invoice-' + reference + '.pdf';
        return res;
    }

    // ── Inner wrappers ───────────────────────────────────────────────────────
    public class ResourceWrapper {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  description;
        @AuraEnabled public String  resourceType;
        @AuraEnabled public Integer capacity;
        @AuraEnabled public String  location;
        @AuraEnabled public Decimal basePrice;
        @AuraEnabled public String  priceUnit;
        @AuraEnabled public String  currency;
        @AuraEnabled public String  imageUrl;
        @AuraEnabled public String  status;
        @AuraEnabled public List<TimeSlotWrapper> timeSlots;
    }

    public class TimeSlotWrapper {
        @AuraEnabled public String  id;
        @AuraEnabled public String  label;
        @AuraEnabled public Integer startHour;
        @AuraEnabled public Integer duration;
        @AuraEnabled public Boolean unavailable;
    }

    public class HoldResult {
        @AuraEnabled public String   holdId;
        @AuraEnabled public Datetime expiresAt;
    }

    public class ConfirmationWrapper {
        @AuraEnabled public String   bookingId;
        @AuraEnabled public String   resourceName;
        @AuraEnabled public Datetime startDatetime;
        @AuraEnabled public Datetime endDatetime;
        @AuraEnabled public Integer  partySize;
        @AuraEnabled public Decimal  totalAmount;
        @AuraEnabled public String   currency;
        @AuraEnabled public String   transactionId;
        @AuraEnabled public String   paymentMethodLabel;
        @AuraEnabled public Boolean  isSplit;
        @AuraEnabled public Integer  splitCount;
        @AuraEnabled public Decimal  splitAmount;
        @AuraEnabled public Datetime freeCancelBy;
        @AuraEnabled public Integer  cancellationPenalty;
        @AuraEnabled public String   customerEmail;
    }

    public class InvoiceResult {
        @AuraEnabled public String base64;
        @AuraEnabled public String filename;
    }
}
