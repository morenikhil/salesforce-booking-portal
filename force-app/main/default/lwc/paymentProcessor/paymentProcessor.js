import { LightningElement, api, track, wire } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import STRIPE_JS      from '@salesforce/resourceUrl/StripeJS';
import getStripePublishableKey from '@salesforce/apex/PaymentController.getStripePublishableKey';
import getSavedPaymentMethods  from '@salesforce/apex/PaymentController.getSavedPaymentMethods';
import processPayment          from '@salesforce/apex/PaymentController.processPayment';
import initPayPalOrder         from '@salesforce/apex/PaymentController.initPayPalOrder';

const COUNTRIES = [
    { label: 'United States', value: 'US' },
    { label: 'United Kingdom', value: 'GB' },
    { label: 'Canada', value: 'CA' },
    { label: 'Australia', value: 'AU' },
    { label: 'India', value: 'IN' },
];

export default class PaymentProcessor extends LightningElement {
    @api bookingDraft = {};

    @track selectedMethod  = 'card';
    @track isProcessing    = false;
    @track stripeError     = '';
    @track cardName        = '';
    @track splitEnabled    = false;
    @track splitCount      = 2;
    @track sameAsProfile   = true;
    @track savedMethods    = [];
    @track selectedSavedMethodId = null;
    @track billingAddress  = { line1: '', city: '', postalCode: '', country: 'US' };

    stripeInstance   = null;
    stripeElements   = null;
    stripeCardNumber = null;
    stripeCardExpiry = null;
    stripeCardCvc    = null;
    stripeLoaded     = false;
    paypalLoaded     = false;

    get countryOptions()   { return COUNTRIES; }
    get isCardMethod()     { return this.selectedMethod === 'card'; }
    get isPaypalMethod()   { return this.selectedMethod === 'paypal'; }
    get isSavedMethod()    { return this.selectedMethod === 'saved'; }
    get hasSavedMethods()  { return this.savedMethods.length > 0; }

    get cardTabCss()   { return this.tabCss('card'); }
    get paypalTabCss() { return this.tabCss('paypal'); }
    get savedTabCss()  { return this.tabCss('saved'); }
    tabCss(m)          { return ['method-tab', this.selectedMethod === m ? 'active' : ''].join(' ').trim(); }

    get splitAmountFormatted() {
        if (!this.splitEnabled || this.splitCount < 2) return '';
        const each = (this.bookingDraft.pricing?.totalAmount || 0) / this.splitCount;
        return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(each);
    }

    get payButtonLabel() {
        const total = this.bookingDraft.pricing?.formattedTotal || '';
        if (this.splitEnabled) return `Pay My Share (${this.splitAmountFormatted})`;
        return `Pay ${total}`;
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    async connectedCallback() {
        await Promise.all([
            this.initStripe(),
            this.loadSavedMethods(),
        ]);
    }

    async initStripe() {
        try {
            await loadScript(this, STRIPE_JS);
            const key = await getStripePublishableKey();
            // eslint-disable-next-line no-undef
            this.stripeInstance = Stripe(key);
            this.stripeLoaded   = true;
            // mount elements after render so DOM nodes exist
            requestAnimationFrame(() => this.mountStripeElements());
        } catch (e) {
            console.error('Stripe init failed', e);
        }
    }

    mountStripeElements() {
        if (!this.stripeLoaded) return;
        const style = {
            base: { fontSize: '16px', color: '#1d1d1f', '::placeholder': { color: '#6e6e73' } },
            invalid: { color: '#e3000f' },
        };
        this.stripeElements   = this.stripeInstance.elements();
        this.stripeCardNumber = this.stripeElements.create('cardNumber', { style });
        this.stripeCardExpiry = this.stripeElements.create('cardExpiry',  { style });
        this.stripeCardCvc    = this.stripeElements.create('cardCvc',     { style });

        const mount = (el, selector) => {
            const node = this.template.querySelector(selector);
            if (node) el.mount(node);
        };
        mount(this.stripeCardNumber, '#stripe-card-number');
        mount(this.stripeCardExpiry, '#stripe-card-expiry');
        mount(this.stripeCardCvc,    '#stripe-card-cvc');

        this.stripeCardNumber.on('change', evt => {
            this.stripeError = evt.error ? evt.error.message : '';
        });
    }

    async loadSavedMethods() {
        try {
            const methods = await getSavedPaymentMethods();
            this.savedMethods = methods.map((m, i) => ({
                ...m,
                icon:      m.brand === 'paypal' ? 'utility:world' : 'utility:credit_card',
                isSelected: i === 0,
                cssClass:  ['saved-method-item', i === 0 ? 'selected' : ''].join(' ').trim(),
            }));
            if (this.savedMethods.length) this.selectedSavedMethodId = this.savedMethods[0].id;
        } catch (e) {
            this.savedMethods = [];
        }
    }

    // ── UI handlers ───────────────────────────────────────────────────────────
    selectMethod(evt)        { this.selectedMethod = evt.currentTarget.dataset.method; }
    handleCardName(evt)      { this.cardName = evt.detail.value; }
    handleSplitToggle(evt)   { this.splitEnabled = evt.detail.checked; }
    handleSplitCountChange(evt) { this.splitCount = parseInt(evt.detail.value, 10) || 2; }
    handleAddressToggle(evt) { this.sameAsProfile = evt.detail.checked; }
    handleAddressChange(evt) {
        const field = evt.currentTarget.dataset.field;
        this.billingAddress = { ...this.billingAddress, [field]: evt.detail.value };
    }
    handleCountryChange(evt) {
        this.billingAddress = { ...this.billingAddress, country: evt.detail.value };
    }
    selectSavedMethod(evt) {
        const id = evt.currentTarget.dataset.id;
        this.selectedSavedMethodId = id;
        this.savedMethods = this.savedMethods.map(m => ({
            ...m,
            isSelected: m.id === id,
            cssClass: ['saved-method-item', m.id === id ? 'selected' : ''].join(' ').trim(),
        }));
    }

    // ── Payment submission ────────────────────────────────────────────────────
    async submitPayment() {
        this.isProcessing = true;
        this.stripeError  = '';
        try {
            let paymentMethodId;

            if (this.selectedMethod === 'card') {
                paymentMethodId = await this.tokenizeCard();
            } else if (this.selectedMethod === 'saved') {
                paymentMethodId = this.selectedSavedMethodId;
            } else if (this.selectedMethod === 'paypal') {
                await this.handlePayPal();
                return; // PayPal flow fires its own completion event
            }

            const result = await processPayment({
                bookingDraftJson:   JSON.stringify(this.bookingDraft),
                paymentMethodId,
                splitEnabled:       this.splitEnabled,
                splitCount:         this.splitEnabled ? this.splitCount : 1,
                billingAddressJson: this.sameAsProfile ? null : JSON.stringify(this.billingAddress),
            });

            this.dispatchEvent(new CustomEvent('paymentcomplete', {
                detail: { bookingReference: result.bookingReference },
            }));
        } catch (e) {
            this.stripeError = e.body?.message || 'Payment failed. Please try again.';
        } finally {
            this.isProcessing = false;
        }
    }

    async tokenizeCard() {
        const { paymentMethod, error } = await this.stripeInstance.createPaymentMethod({
            type: 'card',
            card: this.stripeCardNumber,
            billing_details: { name: this.cardName },
        });
        if (error) throw new Error(error.message);
        return paymentMethod.id;
    }

    async handlePayPal() {
        const order = await initPayPalOrder({ bookingDraftJson: JSON.stringify(this.bookingDraft) });
        // PayPal JS SDK (loaded separately) opens popup — resolve handled via webhook + platform event
        window.open(order.approvalUrl, '_blank', 'width=600,height=700');
        this.isProcessing = false;
    }

    handleBack() { this.dispatchEvent(new CustomEvent('back')); }
}
