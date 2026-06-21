public with sharing class PricingController {

    // ── Dynamic price calculation ────────────────────────────────────────────
    @AuraEnabled
    public static PricingResult calculatePrice(
        Id      resourceId,
        String  slotId,
        Integer partySize,
        Id      promoId,
        Boolean useLoyaltyPoints,
        Integer loyaltyPointsToUse
    ) {
        Booking_Listing__c listing = [
            SELECT Id, Base_Price__c, Price_Unit__c, Currency__c,
                   Tax_Rate__c, Surge_Enabled__c, Surge_Threshold__c,
                   Surge_Multiplier__c, Seasonal_Rate__c, Season_Label__c,
                   Cancellation_Penalty_Pct__c
            FROM   Booking_Listing__c
            WHERE  Id = :resourceId
            WITH   SECURITY_ENFORCED
            LIMIT  1
        ];

        Decimal base     = listing.Base_Price__c != null ? listing.Base_Price__c : 0;
        Decimal taxRate  = listing.Tax_Rate__c   != null ? listing.Tax_Rate__c   : 0;
        Decimal running  = base;

        // ── Surge pricing ────────────────────────────────────────────────────
        Decimal surgeAmount = 0;
        Decimal surgePercent = 0;
        if (listing.Surge_Enabled__c) {
            Integer recentBookings = countRecentBookings(resourceId);
            if (recentBookings >= (listing.Surge_Threshold__c != null ? listing.Surge_Threshold__c.intValue() : 5)) {
                Decimal multiplier = listing.Surge_Multiplier__c != null ? listing.Surge_Multiplier__c : 1.2;
                surgeAmount  = (base * multiplier) - base;
                surgePercent = ((multiplier - 1) * 100).setScale(0);
                running     += surgeAmount;
            }
        }

        // ── Seasonal rate ────────────────────────────────────────────────────
        Decimal seasonalAmount = 0;
        String  seasonLabel    = '';
        if (listing.Seasonal_Rate__c != null && listing.Seasonal_Rate__c != 0) {
            seasonalAmount = base * (listing.Seasonal_Rate__c / 100);
            seasonLabel    = listing.Season_Label__c != null ? listing.Season_Label__c : 'Seasonal adjustment';
            running       += seasonalAmount;
        }

        // ── Promo / coupon discount ──────────────────────────────────────────
        Decimal discountAmount = 0;
        String  discountLabel  = '';
        if (promoId != null) {
            PromoDiscountResult promo = applyPromo(promoId, running);
            discountAmount = promo.discountAmount;
            discountLabel  = promo.label;
            running       -= discountAmount;
        }

        // ── Loyalty points redemption ────────────────────────────────────────
        Decimal loyaltySavings = 0;
        if (useLoyaltyPoints && loyaltyPointsToUse > 0) {
            // 100 pts = $1 USD
            loyaltySavings = Decimal.valueOf(loyaltyPointsToUse) / 100;
            loyaltySavings = loyaltySavings.min(running); // cannot exceed subtotal
            running       -= loyaltySavings;
        }

        // ── Tax ──────────────────────────────────────────────────────────────
        Decimal taxAmount = (running * taxRate / 100).setScale(2);
        Decimal total     = (running + taxAmount).setScale(2);

        PricingResult res   = new PricingResult();
        res.baseAmount      = base.setScale(2);
        res.surgeAmount     = surgeAmount.setScale(2);
        res.surgePercent    = surgePercent.intValue();
        res.seasonalAmount  = seasonalAmount.setScale(2);
        res.seasonLabel     = seasonLabel;
        res.discountAmount  = discountAmount.setScale(2);
        res.discountLabel   = discountLabel;
        res.loyaltySavings  = loyaltySavings.setScale(2);
        res.taxAmount       = taxAmount;
        res.taxRate         = taxRate.intValue();
        res.totalAmount     = total;
        res.currency        = listing.Currency__c != null ? listing.Currency__c : 'USD';
        return res;
    }

    private static Integer countRecentBookings(Id listingId) {
        return [
            SELECT COUNT()
            FROM   Booking__c
            WHERE  Listing__c      = :listingId
            AND    CreatedDate    >= :Datetime.now().addHours(-1)
            AND    Status__c NOT IN ('Cancelled', 'Expired')
        ];
    }

    private static PromoDiscountResult applyPromo(Id promoId, Decimal subtotal) {
        Promo_Code__c promo = [
            SELECT Id, Discount_Type__c, Discount_Value__c, Name
            FROM   Promo_Code__c
            WHERE  Id = :promoId
            WITH   SECURITY_ENFORCED
            LIMIT  1
        ];

        PromoDiscountResult res = new PromoDiscountResult();
        res.label = promo.Name;
        if (promo.Discount_Type__c == 'Percentage') {
            res.discountAmount = (subtotal * promo.Discount_Value__c / 100).setScale(2);
        } else {
            // Fixed amount — cannot exceed subtotal
            res.discountAmount = promo.Discount_Value__c.min(subtotal);
        }
        return res;
    }

    // ── Validate promo code ──────────────────────────────────────────────────
    @AuraEnabled
    public static PromoValidationResult validatePromoCode(String code, Id resourceId, Decimal totalAmount) {
        List<Promo_Code__c> promos = [
            SELECT Id, Code__c, Description__c, Discount_Type__c, Discount_Value__c,
                   Valid_From__c, Valid_To__c, Max_Uses__c, Current_Uses__c,
                   Applicable_Listing__c, Min_Order_Amount__c, Is_Active__c
            FROM   Promo_Code__c
            WHERE  Code__c     = :code
            AND    Is_Active__c = true
            WITH   SECURITY_ENFORCED
            LIMIT  1
        ];

        PromoValidationResult res = new PromoValidationResult();
        if (promos.isEmpty()) {
            res.valid  = false;
            res.reason = 'Code not found.';
            return res;
        }

        Promo_Code__c p = promos[0];
        Date today = Date.today();

        if (p.Valid_From__c != null && today < p.Valid_From__c) {
            res.valid = false; res.reason = 'Promo not yet active.'; return res;
        }
        if (p.Valid_To__c != null && today > p.Valid_To__c) {
            res.valid = false; res.reason = 'Promo has expired.'; return res;
        }
        if (p.Max_Uses__c != null && p.Current_Uses__c >= p.Max_Uses__c) {
            res.valid = false; res.reason = 'Promo code has reached its usage limit.'; return res;
        }
        if (p.Min_Order_Amount__c != null && totalAmount < p.Min_Order_Amount__c) {
            res.valid = false; res.reason = 'Minimum order amount not met.'; return res;
        }
        if (p.Applicable_Listing__c != null && p.Applicable_Listing__c != resourceId) {
            res.valid = false; res.reason = 'Promo not applicable to this resource.'; return res;
        }

        res.valid       = true;
        res.promoId     = p.Id;
        res.description = p.Description__c;
        return res;
    }

    // ── Get loyalty balance ──────────────────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static Integer getLoyaltyBalance() {
        List<Loyalty_Account__c> accounts = [
            SELECT Points_Balance__c
            FROM   Loyalty_Account__c
            WHERE  Contact__r.User__c = :UserInfo.getUserId()
            WITH   SECURITY_ENFORCED
            LIMIT  1
        ];
        return accounts.isEmpty() ? 0 : accounts[0].Points_Balance__c.intValue();
    }

    // ── Inner wrappers ───────────────────────────────────────────────────────
    public class PricingResult {
        @AuraEnabled public Decimal baseAmount;
        @AuraEnabled public Decimal surgeAmount;
        @AuraEnabled public Integer surgePercent;
        @AuraEnabled public Decimal seasonalAmount;
        @AuraEnabled public String  seasonLabel;
        @AuraEnabled public Decimal discountAmount;
        @AuraEnabled public String  discountLabel;
        @AuraEnabled public Decimal loyaltySavings;
        @AuraEnabled public Decimal taxAmount;
        @AuraEnabled public Integer taxRate;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public String  currency;
    }

    public class PromoDiscountResult {
        public Decimal discountAmount;
        public String  label;
    }

    public class PromoValidationResult {
        @AuraEnabled public Boolean valid;
        @AuraEnabled public String  promoId;
        @AuraEnabled public String  description;
        @AuraEnabled public String  reason;
    }
}
