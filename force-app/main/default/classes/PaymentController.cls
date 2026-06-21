public with sharing class PaymentController {

    private static final String STRIPE_NAMED_CRED = 'Stripe_API';

    // ── Stripe publishable key (stored in Custom Metadata) ───────────────────
    @AuraEnabled(cacheable=true)
    public static String getStripePublishableKey() {
        Payment_Gateway_Config__mdt cfg = [
            SELECT Stripe_Publishable_Key__c
            FROM   Payment_Gateway_Config__mdt
            WHERE  DeveloperName = 'Default'
            LIMIT  1
        ];
        return cfg.Stripe_Publishable_Key__c;
    }

    // ── Saved payment methods for the current user ───────────────────────────
    @AuraEnabled(cacheable=true)
    public static List<SavedMethodWrapper> getSavedPaymentMethods() {
        List<Payment_Method__c> methods = [
            SELECT Id, Label__c, Sub_Label__c, Brand__c, Gateway__c
            FROM   Payment_Method__c
            WHERE  Contact__r.User__c = :UserInfo.getUserId()
            AND    Is_Active__c       = true
            WITH   SECURITY_ENFORCED
            ORDER BY CreatedDate DESC
            LIMIT  10
        ];

        List<SavedMethodWrapper> results = new List<SavedMethodWrapper>();
        for (Payment_Method__c m : methods) {
            SavedMethodWrapper w = new SavedMethodWrapper();
            w.id       = m.Id;
            w.label    = m.Label__c;
            w.sublabel = m.Sub_Label__c;
            w.brand    = m.Brand__c;
            w.gateway  = m.Gateway__c;
            results.add(w);
        }
        return results;
    }

    // ── Process payment ──────────────────────────────────────────────────────
    @AuraEnabled
    public static PaymentResult processPayment(
        String  bookingDraftJson,
        String  paymentMethodId,
        Boolean splitEnabled,
        Integer splitCount,
        String  billingAddressJson
    ) {
        Map<String, Object> draft = (Map<String, Object>) JSON.deserializeUntyped(bookingDraftJson);
        Map<String, Object> pricing = (Map<String, Object>) draft.get('pricing');

        Decimal totalAmount = Decimal.valueOf(String.valueOf(pricing.get('totalAmount')));
        String  currency    = (String)  draft.get('currency');
        String  holdId      = (String)  draft.get('holdId');

        // Charge via Stripe
        Map<String, Object> chargeResult = chargeStripe(
            paymentMethodId,
            (totalAmount * 100).intValue(), // Stripe uses cents
            currency != null ? currency.toLowerCase() : 'usd',
            (String) draft.get('resourceName')
        );

        if (!(Boolean) chargeResult.get('success')) {
            throw new AuraHandledException((String) chargeResult.get('error'));
        }

        // Create Booking record
        Booking__c booking = buildBooking(draft, pricing, chargeResult, splitEnabled, splitCount, paymentMethodId);
        insert booking;

        // Release the hold
        if (String.isNotBlank(holdId)) {
            releaseHold(Id.valueOf(holdId));
        }

        // Consume promo usage if applicable
        String promoId = (String) pricing.get('appliedPromoId');
        if (String.isNotBlank(promoId)) {
            incrementPromoUsage(Id.valueOf(promoId));
        }

        // Deduct loyalty points
        Boolean useLoyalty = (Boolean) pricing.get('useLoyaltyPoints');
        Integer ptsToUse   = pricing.get('loyaltyPointsToUse') != null
            ? Integer.valueOf(String.valueOf(pricing.get('loyaltyPointsToUse'))) : 0;
        if (useLoyalty == true && ptsToUse > 0) {
            deductLoyaltyPoints(ptsToUse);
        }

        // Fire platform event so notification flow picks it up
        BookingEvent__e evt = new BookingEvent__e(
            Booking_Id__c   = booking.Id,
            Reference__c    = booking.Booking_Reference__c,
            Event_Type__c   = 'BOOKING_CONFIRMED'
        );
        EventBus.publish(evt);

        PaymentResult res    = new PaymentResult();
        res.bookingReference = booking.Booking_Reference__c;
        res.transactionId    = (String) chargeResult.get('transactionId');
        return res;
    }

    // ── Stripe callout ───────────────────────────────────────────────────────
    private static Map<String, Object> chargeStripe(
        String paymentMethodId, Integer amountCents, String currency, String description
    ) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + STRIPE_NAMED_CRED + '/v1/payment_intents');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setBody(
            'amount='             + amountCents +
            '&currency='          + EncodingUtil.urlEncode(currency, 'UTF-8') +
            '&payment_method='    + EncodingUtil.urlEncode(paymentMethodId, 'UTF-8') +
            '&description='       + EncodingUtil.urlEncode(description, 'UTF-8') +
            '&confirm=true' +
            '&automatic_payment_methods[enabled]=true' +
            '&automatic_payment_methods[allow_redirects]=never'
        );

        Http http = new Http();
        HttpResponse res = http.send(req);

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> result = new Map<String, Object>();

        if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
            result.put('success',       true);
            result.put('transactionId', (String) body.get('id'));
        } else {
            Map<String, Object> error = (Map<String, Object>) body.get('error');
            result.put('success', false);
            result.put('error', error != null ? (String) error.get('message') : 'Payment declined.');
        }
        return result;
    }

    // ── Build the Booking__c record from draft data ──────────────────────────
    private static Booking__c buildBooking(
        Map<String, Object> draft,
        Map<String, Object> pricing,
        Map<String, Object> chargeResult,
        Boolean splitEnabled,
        Integer splitCount,
        String paymentMethodId
    ) {
        Decimal total = Decimal.valueOf(String.valueOf(pricing.get('totalAmount')));
        Booking__c b  = new Booking__c();
        b.Listing__c              = Id.valueOf((String) draft.get('resourceId'));
        b.Booking_Date__c         = Date.valueOf((String) draft.get('date'));
        b.Slot_Id__c              = (String) draft.get('slotId');
        b.Party_Size__c           = Integer.valueOf(String.valueOf(draft.get('partySize')));
        b.Total_Amount__c         = total;
        b.Currency__c             = (String) draft.get('currency');
        b.Status__c               = 'Confirmed';
        b.Transaction_Id__c       = (String) chargeResult.get('transactionId');
        b.Payment_Method_Id__c    = paymentMethodId;
        b.Payment_Method_Label__c = 'Card ending ****';
        b.Is_Split__c             = splitEnabled;
        b.Split_Count__c          = splitEnabled ? splitCount : 1;
        b.Split_Amount__c         = splitEnabled ? (total / splitCount).setScale(2) : total;
        b.Booking_Reference__c    = generateReference();
        b.Contact__c              = getContactForCurrentUser();
        b.Free_Cancel_By__c       = Datetime.now().addHours(24);
        b.Cancellation_Penalty_Pct__c = 25;
        return b;
    }

    private static String generateReference() {
        String chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
        String ref   = 'BK-';
        for (Integer i = 0; i < 8; i++) {
            Integer idx = Math.mod(Math.abs(Crypto.getRandomInteger()), chars.length());
            ref += chars.substring(idx, idx + 1);
        }
        return ref;
    }

    private static Id getContactForCurrentUser() {
        List<Contact> contacts = [
            SELECT Id FROM Contact WHERE User__c = :UserInfo.getUserId() LIMIT 1
        ];
        return contacts.isEmpty() ? null : contacts[0].Id;
    }

    private static void releaseHold(Id holdId) {
        Booking_Hold__c hold = new Booking_Hold__c(Id = holdId, Status__c = 'Released');
        update hold;
    }

    private static void incrementPromoUsage(Id promoId) {
        Promo_Code__c promo = [SELECT Id, Current_Uses__c FROM Promo_Code__c WHERE Id = :promoId LIMIT 1];
        promo.Current_Uses__c = (promo.Current_Uses__c != null ? promo.Current_Uses__c : 0) + 1;
        update promo;
    }

    private static void deductLoyaltyPoints(Integer pts) {
        List<Loyalty_Account__c> accounts = [
            SELECT Id, Points_Balance__c
            FROM   Loyalty_Account__c
            WHERE  Contact__r.User__c = :UserInfo.getUserId()
            LIMIT  1
        ];
        if (accounts.isEmpty()) return;
        Loyalty_Account__c acc = accounts[0];
        acc.Points_Balance__c  = (acc.Points_Balance__c - pts).max(0);
        update acc;
    }

    // ── PayPal order init ────────────────────────────────────────────────────
    @AuraEnabled
    public static PayPalOrderResult initPayPalOrder(String bookingDraftJson) {
        Map<String, Object> draft   = (Map<String, Object>) JSON.deserializeUntyped(bookingDraftJson);
        Map<String, Object> pricing = (Map<String, Object>) draft.get('pricing');
        Decimal total = Decimal.valueOf(String.valueOf(pricing.get('totalAmount')));

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:PayPal_API/v2/checkout/orders');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{
            'intent' => 'CAPTURE',
            'purchase_units' => new List<Object>{
                new Map<String, Object>{
                    'amount' => new Map<String, Object>{
                        'currency_code' => (String) draft.get('currency'),
                        'value'         => String.valueOf(total)
                    },
                    'description' => (String) draft.get('resourceName')
                }
            }
        }));

        Http http = new Http();
        HttpResponse res = http.send(req);
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

        PayPalOrderResult result = new PayPalOrderResult();
        result.orderId = (String) body.get('id');
        // Find approval link
        List<Object> links = (List<Object>) body.get('links');
        for (Object lnk : links) {
            Map<String, Object> l = (Map<String, Object>) lnk;
            if (l.get('rel') == 'approve') {
                result.approvalUrl = (String) l.get('href');
                break;
            }
        }
        return result;
    }

    // ── Inner wrappers ───────────────────────────────────────────────────────
    public class SavedMethodWrapper {
        @AuraEnabled public String id;
        @AuraEnabled public String label;
        @AuraEnabled public String sublabel;
        @AuraEnabled public String brand;
        @AuraEnabled public String gateway;
    }

    public class PaymentResult {
        @AuraEnabled public String bookingReference;
        @AuraEnabled public String transactionId;
    }

    public class PayPalOrderResult {
        @AuraEnabled public String orderId;
        @AuraEnabled public String approvalUrl;
    }
}
