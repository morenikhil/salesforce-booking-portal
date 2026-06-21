import { LightningElement, api, track } from 'lwc';
import calculatePrice    from '@salesforce/apex/PricingController.calculatePrice';
import validatePromoCode from '@salesforce/apex/PricingController.validatePromoCode';
import getLoyaltyBalance from '@salesforce/apex/PricingController.getLoyaltyBalance';

export default class PricingPanel extends LightningElement {
    @api bookingDraft = {};

    @track pricing          = {};
    @track promoCode        = '';
    @track promoApplied     = false;
    @track promoMessage     = '';
    @track promoValid       = false;
    @track isApplyingPromo  = false;
    @track isRecalculating  = false;

    @track hasLoyaltyPoints = false;
    @track loyaltyBalance   = 0;
    @track useLoyaltyPoints = false;
    @track loyaltyPointsToUse = 0;

    appliedPromoId = null;

    get promoCssClass() {
        return this.promoValid ? 'promo-msg promo-success' : 'promo-msg promo-error';
    }

    get loyaltyToggleLabel() {
        return `Use loyalty points (${this.loyaltyBalance} pts = ${this.pricing.formattedLoyaltySavings || '$0'} off)`;
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────
    async connectedCallback() {
        await Promise.all([this.recalculate(), this.fetchLoyaltyBalance()]);
    }

    async recalculate() {
        this.isRecalculating = true;
        try {
            const result = await calculatePrice({
                resourceId:      this.bookingDraft.resourceId,
                slotId:          this.bookingDraft.slotId,
                partySize:       this.bookingDraft.partySize,
                promoId:         this.appliedPromoId,
                useLoyaltyPoints: this.useLoyaltyPoints,
                loyaltyPointsToUse: this.loyaltyPointsToUse,
            });
            this.pricing = this.enrichPricing(result);
        } catch (e) {
            console.error('Price calculation failed', e);
        } finally {
            this.isRecalculating = false;
        }
    }

    enrichPricing(p) {
        const fmt = (v) => new Intl.NumberFormat('en-US', { style: 'currency', currency: this.bookingDraft.currency || 'USD' }).format(v || 0);
        return {
            ...p,
            formattedBase:         fmt(p.baseAmount),
            formattedSurge:        fmt(p.surgeAmount),
            formattedSeasonal:     fmt(p.seasonalAmount),
            formattedDiscount:     fmt(p.discountAmount),
            formattedTax:          fmt(p.taxAmount),
            formattedTotal:        fmt(p.totalAmount),
            formattedLoyaltySavings: fmt(p.loyaltySavings),
            hasSurge:    (p.surgeAmount   || 0) > 0,
            hasSeasonal: (p.seasonalAmount || 0) !== 0,
            hasDiscount: (p.discountAmount || 0) > 0,
        };
    }

    async fetchLoyaltyBalance() {
        try {
            const balance = await getLoyaltyBalance();
            this.loyaltyBalance   = balance;
            this.hasLoyaltyPoints = balance > 0;
        } catch (e) {
            this.hasLoyaltyPoints = false;
        }
    }

    // ── Promo code ────────────────────────────────────────────────────────────
    handlePromoInput(evt) { this.promoCode = evt.detail.value; }

    async applyPromo() {
        if (!this.promoCode.trim()) return;
        this.isApplyingPromo = true;
        this.promoMessage    = '';
        try {
            const result = await validatePromoCode({
                code:       this.promoCode.trim().toUpperCase(),
                resourceId: this.bookingDraft.resourceId,
                totalAmount: this.pricing.totalAmount,
            });
            if (result.valid) {
                this.appliedPromoId = result.promoId;
                this.promoApplied   = true;
                this.promoValid     = true;
                this.promoMessage   = `✓ ${result.description} applied`;
                await this.recalculate();
            } else {
                this.promoValid   = false;
                this.promoMessage = result.reason || 'Invalid or expired promo code.';
            }
        } catch (e) {
            this.promoValid   = false;
            this.promoMessage = 'Could not validate promo code. Please try again.';
        } finally {
            this.isApplyingPromo = false;
        }
    }

    removePromo() {
        this.appliedPromoId = null;
        this.promoApplied   = false;
        this.promoCode      = '';
        this.promoMessage   = '';
        this.recalculate();
    }

    // ── Loyalty ───────────────────────────────────────────────────────────────
    async handleLoyaltyToggle(evt) {
        this.useLoyaltyPoints    = evt.detail.checked;
        this.loyaltyPointsToUse  = this.useLoyaltyPoints ? this.loyaltyBalance : 0;
        await this.recalculate();
    }

    // ── Navigation ────────────────────────────────────────────────────────────
    handleBack() { this.dispatchEvent(new CustomEvent('back')); }

    confirmPricing() {
        this.dispatchEvent(new CustomEvent('pricingconfirmed', {
            detail: {
                ...this.pricing,
                appliedPromoId:     this.appliedPromoId,
                useLoyaltyPoints:   this.useLoyaltyPoints,
                loyaltyPointsToUse: this.loyaltyPointsToUse,
            },
        }));
    }
}
