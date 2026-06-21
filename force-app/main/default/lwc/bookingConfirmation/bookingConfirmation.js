import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getConfirmationDetails from '@salesforce/apex/BookingEngineController.getConfirmationDetails';
import generateInvoicePdf     from '@salesforce/apex/BookingEngineController.generateInvoicePdf';

export default class BookingConfirmation extends NavigationMixin(LightningElement) {
    @api bookingReference;

    @track confirmation   = {};
    @track customerEmail  = '';
    @track copyLabel      = 'Copy';
    @track isLoading      = true;

    // ── Load confirmation data ───────────────────────────────────────────────
    async connectedCallback() {
        try {
            const data = await getConfirmationDetails({ reference: this.bookingReference });
            this.confirmation  = this.enrichConfirmation(data);
            this.customerEmail = data.customerEmail;
        } catch (e) {
            console.error('Failed to load confirmation', e);
        } finally {
            this.isLoading = false;
        }
    }

    enrichConfirmation(d) {
        const fmt     = v => new Intl.NumberFormat('en-US', { style: 'currency', currency: d.currency || 'USD' }).format(v || 0);
        const fmtDate = v => v ? new Date(v).toLocaleString('en-US', { dateStyle: 'full', timeStyle: 'short' }) : '';
        return {
            ...d,
            formattedTotal:        fmt(d.totalAmount),
            formattedSplitAmount:  fmt(d.splitAmount),
            formattedDateTime:     fmtDate(d.startDatetime),
            freeCancelByFormatted: fmtDate(d.freeCancelBy),
        };
    }

    // ── Copy reference ───────────────────────────────────────────────────────
    copyReference() {
        navigator.clipboard.writeText(this.bookingReference).then(() => {
            this.copyLabel = 'Copied!';
            setTimeout(() => { this.copyLabel = 'Copy'; }, 2000);
        });
    }

    // ── Calendar links ───────────────────────────────────────────────────────
    addToGoogle() {
        const c = this.confirmation;
        const start = encodeURIComponent(new Date(c.startDatetime).toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z');
        const end   = encodeURIComponent(new Date(c.endDatetime).toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z');
        const text  = encodeURIComponent(c.resourceName);
        const url   = `https://calendar.google.com/calendar/render?action=TEMPLATE&text=${text}&dates=${start}/${end}&details=Booking+Ref:+${this.bookingReference}`;
        window.open(url, '_blank');
    }

    addToOutlook() {
        const c   = this.confirmation;
        const ics = [
            'BEGIN:VCALENDAR',
            'VERSION:2.0',
            'BEGIN:VEVENT',
            `SUMMARY:${c.resourceName}`,
            `DTSTART:${new Date(c.startDatetime).toISOString().replace(/[-:]/g, '').split('.')[0]}Z`,
            `DTEND:${new Date(c.endDatetime).toISOString().replace(/[-:]/g, '').split('.')[0]}Z`,
            `DESCRIPTION:Booking Reference: ${this.bookingReference}`,
            'END:VEVENT',
            'END:VCALENDAR',
        ].join('\r\n');
        const blob = new Blob([ics], { type: 'text/calendar' });
        const a    = document.createElement('a');
        a.href     = URL.createObjectURL(blob);
        a.download = `booking-${this.bookingReference}.ics`;
        a.click();
    }

    // ── Invoice download ─────────────────────────────────────────────────────
    async downloadInvoice() {
        try {
            const result = await generateInvoicePdf({ reference: this.bookingReference });
            const a      = document.createElement('a');
            a.href       = `data:application/pdf;base64,${result.base64}`;
            a.download   = `invoice-${this.bookingReference}.pdf`;
            a.click();
        } catch (e) {
            console.error('Invoice generation failed', e);
        }
    }

    // ── Navigate to My Bookings ──────────────────────────────────────────────
    goToMyBookings() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'My_Bookings' },
        });
    }
}
