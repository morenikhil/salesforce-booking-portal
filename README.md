# Salesforce Booking Portal

A full-featured, multi-purpose booking portal built entirely on the Salesforce platform using Lightning Web Components (LWC), Apex, and native Salesforce automation. Covers the complete booking lifecycle — discovery, reservation, payment, confirmation, and operations.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Module Map](#2-module-map)
3. [Booking Flow — Core Modules](#3-booking-flow--core-modules)
   - [3.1 Booking Engine](#31-booking-engine)
   - [3.2 Pricing & Promotions](#32-pricing--promotions)
   - [3.3 Payment Processing](#33-payment-processing)
4. [LWC Component Reference](#4-lwc-component-reference)
5. [Apex Controller Reference](#5-apex-controller-reference)
6. [Custom Object Map](#6-custom-object-map)
7. [Architecture Diagrams](#7-architecture-diagrams)
8. [Project File Structure](#8-project-file-structure)
9. [Prerequisites](#9-prerequisites)
10. [Setup Guide](#10-setup-guide)
    - [Step 1 — Stripe Named Credential](#step-1--stripe-named-credential)
    - [Step 2 — PayPal Named Credential](#step-2--paypal-named-credential)
    - [Step 3 — Custom Metadata Type](#step-3--custom-metadata-type)
    - [Step 4 — Stripe.js Static Resource](#step-4--stripejs-static-resource)
    - [Step 5 — Deploy to Lightning Page](#step-5--deploy-to-lightning-page)
11. [End-to-End Data Flow](#11-end-to-end-data-flow)
12. [Smoke Test Checklist](#12-smoke-test-checklist)
13. [Platform Automation](#13-platform-automation)
14. [Security & Permissions](#14-security--permissions)
15. [Going Live Checklist](#15-going-live-checklist)

---

## 1. Project Overview

This project implements a **generic multi-purpose booking portal** on a Salesforce Developer Org using only native Salesforce primitives:

| Layer | Technology |
|---|---|
| UI | Lightning Web Components (LWC) |
| Business logic | Apex (`with sharing`) |
| Data | Custom Objects + Platform Events |
| Automation | Flows (Scheduled, Record-Triggered, Platform Event-Triggered) |
| External APIs | Stripe (payments), PayPal (payments), Google Calendar (deep-link), iCal (blob) |
| Config | Custom Metadata Types, Named Credentials, Static Resources |

The booking flow follows a **4-step checkout wizard**:

```
Step 1 — Select resource & time slot
Step 2 — Review pricing & apply promotions
Step 3 — Enter payment details & pay
Step 4 — View booking confirmation & download invoice
```

---

## 2. Module Map

The full platform is grouped into five layers, each containing three modules:

### Discovery layer
| Module | Responsibility |
|---|---|
| User Management | Registration, login, SSO/OAuth, profile, saved preferences |
| Search & Discovery | Filters, keyword search, map search, real-time availability |
| Inventory & Catalog | Bookable items, descriptions, images, pricing rules |

### Booking flow *(implemented in this release)*
| Module | Responsibility |
|---|---|
| **Booking Engine** | Seat/time/resource selection, temporary holds, booking reference generation |
| **Pricing & Promotions** | Dynamic pricing, surge, seasonal rates, coupons, loyalty discounts |
| **Payment Processing** | Stripe, PayPal, split payments, saved methods, invoices, refunds |

### Post-booking layer
| Module | Responsibility |
|---|---|
| Notifications | Confirmation email/SMS, reminders, status updates via Platform Events |
| Cancellation & Refunds | Policy enforcement, penalty calculation, rescheduling |
| Calendar & Scheduling | Time-slot logic, buffer times, Google/Outlook sync |

### Operations layer
| Module | Responsibility |
|---|---|
| Admin Dashboard | Unified staff view of bookings, customers, operational controls |
| Reviews & Ratings | Customer feedback, moderation, ratings on listings |
| Reporting & Analytics | Revenue, occupancy, conversion funnels, KPIs |

### Infrastructure layer
| Module | Responsibility |
|---|---|
| Multi-language & Currency | Localization, date/time formats, currency conversion |
| Integrations & APIs | OTAs, CRMs, ERPs, channel managers |
| Security & Compliance | PCI-DSS, GDPR, fraud detection, audit logging |

---

## 3. Booking Flow — Core Modules

### 3.1 Booking Engine

Handles everything from showing available resources to locking a time slot with a temporary hold.

**Key features:**
- Resource type filtering (Room / Seat / Appointment / Equipment)
- Date, party size, and preferred-time search
- Real-time availability check excluding already-held and confirmed slots
- Time-slot grid generation (hourly slots, 8 AM – 5 PM)
- 10-minute temporary hold with client-side countdown timer
- Automatic hold release on expiry (Scheduled Flow + client-side fallback)
- Cryptographically random booking reference (`BK-XXXXXXXX`)
- Confirmation details: receipt, calendar export, VF-rendered PDF invoice

**Sub-modules:**

```
Search & Availability  →  Hold Management  →  Booking Reference  →  Confirmation Step
```

| Sub-module | Apex method | Object written |
|---|---|---|
| Search & Availability | `searchAvailability()` | reads `Booking_Listing__c`, `Booking_Hold__c` |
| Hold Management | `createHold()`, `releaseHold()` | `Booking_Hold__c` |
| Booking Reference | inside `processPayment()` | `Booking__c.Booking_Reference__c` |
| Confirmation | `getConfirmationDetails()`, `generateInvoicePdf()` | reads `Booking__c` |

---

### 3.2 Pricing & Promotions

Calculates the total charge in a deterministic pipeline applied in this exact order:

```
Base Rate
  + Surge Amount      (if recent bookings ≥ threshold in last 1 hour)
  + Seasonal Amount   (± % from Listing.Seasonal_Rate__c)
  − Promo Discount    (% or fixed, after 6 server-side validation checks)
  − Loyalty Savings   (100 pts = $1, capped at subtotal)
  + Tax               (Listing.Tax_Rate__c % on the post-discount subtotal)
  = Total Due
```

**Promo code validation — 6 checks applied in order:**

1. Code exists and `Is_Active__c = true`
2. `Valid_From__c ≤ today ≤ Valid_To__c`
3. `Current_Uses__c < Max_Uses__c`
4. Order total ≥ `Min_Order_Amount__c`
5. `Applicable_Listing__c` matches (if set)
6. User has not already used this single-use code

**Loyalty points:**
- Balance sourced from `Loyalty_Account__c` linked via `Contact → User`
- Redeemed at 100 pts = $1 (configurable)
- Deducted atomically inside `PaymentController.processPayment()`

---

### 3.3 Payment Processing

Supports four payment methods with a single unified `processPayment()` Apex method:

| Method | Implementation |
|---|---|
| Credit / Debit Card | Stripe.js Elements mounted in LWC → `createPaymentMethod()` → server-side `payment_intents` confirm |
| PayPal | Server creates PayPal Order → returns `approvalUrl` → popup redirect |
| Saved Methods | Stored `Payment_Method__c` records with gateway PM ID |
| Split Payment | Total divided by 2–10 payers; each share shown in UI |

**Post-payment actions (all in one Apex transaction):**
1. Insert `Booking__c` (Status = Confirmed)
2. Release `Booking_Hold__c` (Status = Released)
3. Increment `Promo_Code__c.Current_Uses__c`
4. Deduct `Loyalty_Account__c.Points_Balance__c`
5. Publish `BookingEvent__e` (fires notification Flow)

---

## 4. LWC Component Reference

### Component tree

```
c-booking-checkout-stepper          ← expose on App / Record / Community pages
├── c-resource-selector             ← Step 1: Booking Engine
├── c-pricing-panel                 ← Step 2: Pricing & Promotions
├── c-payment-processor             ← Step 3: Payment Processing
└── c-booking-confirmation          ← Step 4: Confirmation
```

### bookingCheckoutStepper

**File:** `lwc/bookingCheckoutStepper/`  
**Exposed:** Yes (`lightning__AppPage`, `lightning__RecordPage`, `lightning__HomePage`, `lightningCommunity__Page`)

Master orchestrator. Owns step state, the 10-minute hold countdown timer, and the error toast. Passes data down to child components via `@api` properties and listens for upward events.

| Event listened | Fired by | Action |
|---|---|---|
| `resourceselected` | `c-resource-selector` | Stores resource/slot data in `bookingDraft` |
| `holdcreated` | `c-resource-selector` | Starts countdown timer, advances to step 2 |
| `pricingconfirmed` | `c-pricing-panel` | Merges pricing into `bookingDraft`, advances to step 3 |
| `paymentcomplete` | `c-payment-processor` | Stores reference, stops timer, advances to step 4 |
| `back` | `c-pricing-panel`, `c-payment-processor` | Decrements `currentStep` |

---

### resourceSelector

**File:** `lwc/resourceSelector/`  
**Exposed:** No (child only)

Renders the type tab bar, date/party/time filters, available resource cards, and inline time-slot picker. Calls `BookingEngineController.searchAvailability()` and `BookingEngineController.createHold()`.

| Property / Event | Direction | Description |
|---|---|---|
| `onresourceselected` | up | Fires when user clicks Confirm Selection |
| `onholdcreated` | up | Fires after `createHold()` succeeds |

---

### pricingPanel

**File:** `lwc/pricingPanel/`  
**Exposed:** No (child only)

Displays the itemised price breakdown (base, surge, seasonal, discount, loyalty, tax, total). Handles promo code entry and loyalty toggle. Recalculates on every change.

| `@api` prop | Type | Description |
|---|---|---|
| `bookingDraft` | Object | Resource + slot data from step 1 |

| Event | Direction | Description |
|---|---|---|
| `onpricingconfirmed` | up | Fires with full `PricingResult` object |
| `onback` | up | User clicked Back |

---

### paymentProcessor

**File:** `lwc/paymentProcessor/`  
**Exposed:** No (child only)

Loads Stripe.js from Static Resource, mounts card Elements into DOM nodes, handles PayPal popup, and renders saved payment methods. Calls `PaymentController.processPayment()`.

| `@api` prop | Type | Description |
|---|---|---|
| `bookingDraft` | Object | Full draft including `pricing` from step 2 |

| Event | Direction | Description |
|---|---|---|
| `onpaymentcomplete` | up | Fires with `{ bookingReference }` on success |
| `onback` | up | User clicked Back |

---

### bookingConfirmation

**File:** `lwc/bookingConfirmation/`  
**Exposed:** No (child only)

Shows the success banner, reference card (with copy button), details grid, receipt, calendar add buttons, cancellation policy, and invoice download. Uses `NavigationMixin` to navigate to the My Bookings page.

| `@api` prop | Type | Description |
|---|---|---|
| `bookingReference` | String | e.g. `BK-A1B2C3D4` |

---

## 5. Apex Controller Reference

### BookingEngineController.cls

| Method | Access | Description |
|---|---|---|
| `searchAvailability(type, date, time, partySize)` | `@AuraEnabled(cacheable=false)` | SOQL query on listings + holds; returns `ResourceWrapper[]` |
| `createHold(resourceId, slotId, partySize)` | `@AuraEnabled` | Inserts `Booking_Hold__c`; releases any prior hold for the user on the same listing |
| `releaseHold(holdId)` | `@AuraEnabled` | Sets `Booking_Hold__c.Status__c = 'Released'` |
| `getConfirmationDetails(reference)` | `@AuraEnabled(cacheable=true)` | Returns `ConfirmationWrapper` for the given booking reference |
| `generateInvoicePdf(reference)` | `@AuraEnabled` | Renders `BookingInvoicePDF` VF page as base64-encoded PDF |

---

### PricingController.cls

| Method | Access | Description |
|---|---|---|
| `calculatePrice(resourceId, slotId, partySize, promoId, useLoyalty, loyaltyPts)` | `@AuraEnabled` | Runs the full pricing pipeline; returns `PricingResult` |
| `validatePromoCode(code, resourceId, totalAmount)` | `@AuraEnabled` | Runs 6 server-side checks; returns `PromoValidationResult` |
| `getLoyaltyBalance()` | `@AuraEnabled(cacheable=true)` | Returns `Integer` points balance for current user |

---

### PaymentController.cls

| Method | Access | Description |
|---|---|---|
| `getStripePublishableKey()` | `@AuraEnabled(cacheable=true)` | Reads `Payment_Gateway_Config__mdt` |
| `getSavedPaymentMethods()` | `@AuraEnabled(cacheable=true)` | Returns `SavedMethodWrapper[]` for current user |
| `processPayment(draftJson, pmId, split, splitCount, billingJson)` | `@AuraEnabled` | Stripe callout → insert `Booking__c` → release hold → publish event |
| `initPayPalOrder(draftJson)` | `@AuraEnabled` | Creates PayPal Order via Named Credential; returns `approvalUrl` |

---

## 6. Custom Object Map

<img width="4300" height="2900" alt="06-custom-object-map" src="https://github.com/user-attachments/assets/a5f46499-0a46-4965-9bdc-1b941193bf1f" />

### Booking_Listing__c — Catalog

| Field | Type | Notes |
|---|---|---|
| `Name` | Text | Display name of the resource |
| `Resource_Type__c` | Picklist | Room / Seat / Appointment / Equipment |
| `Capacity__c` | Number | Max party size |
| `Location__c` | Text | Physical or virtual location |
| `Base_Price__c` | Currency | Per-unit base rate |
| `Price_Unit__c` | Picklist | hour / day / session |
| `Currency__c` | Text | ISO code (e.g. `USD`) |
| `Tax_Rate__c` | Percent | Applied after all discounts |
| `Surge_Enabled__c` | Checkbox | Activates surge logic |
| `Surge_Threshold__c` | Number | Recent bookings count that triggers surge |
| `Surge_Multiplier__c` | Number | e.g. `1.2` = 20% uplift |
| `Seasonal_Rate__c` | Percent | Positive = uplift, Negative = discount |
| `Season_Label__c` | Text | Badge label shown in UI |
| `Status__c` | Picklist | Active / Inactive |
| `Image_URL__c` | URL | Resource thumbnail |

---

### Booking_Hold__c — Temporary Hold

| Field | Type | Notes |
|---|---|---|
| `Listing__c` | Master-Detail → `Booking_Listing__c` | |
| `Slot_Id__c` | Text | Composite key: `listingId_hour` |
| `Booking_Date__c` | Date | |
| `Party_Size__c` | Number | |
| `Held_By__c` | Lookup → User | |
| `Expires_At__c` | DateTime | `now() + 10 min` |
| `Status__c` | Picklist | Active / Released / Expired |

---

### Booking__c — Confirmed Reservation

| Field | Type | Notes |
|---|---|---|
| `Booking_Reference__c` | Text (unique) | `BK-` + 8 random alphanumeric chars |
| `Listing__c` | Master-Detail → `Booking_Listing__c` | |
| `Contact__c` | Lookup → Contact | |
| `Booking_Date__c` | Date | |
| `Slot_Id__c` | Text | |
| `Start_Datetime__c` | DateTime | |
| `End_Datetime__c` | DateTime | |
| `Party_Size__c` | Number | |
| `Total_Amount__c` | Currency | |
| `Currency__c` | Text | |
| `Status__c` | Picklist | Confirmed / Cancelled / Completed |
| `Transaction_Id__c` | Text | Stripe Payment Intent ID or PayPal Order ID |
| `Payment_Method_Id__c` | Text | Stripe PM ID |
| `Payment_Method_Label__c` | Text | e.g. `Visa ending 4242` |
| `Is_Split__c` | Checkbox | |
| `Split_Count__c` | Number | |
| `Split_Amount__c` | Currency | Per-payer share |
| `Free_Cancel_By__c` | DateTime | `now() + 24 hours` |
| `Cancellation_Penalty_Pct__c` | Percent | Default 25% |

---

### Promo_Code__c — Coupons & Discounts

| Field | Type | Notes |
|---|---|---|
| `Code__c` | Text (unique, external ID) | Entered by user in UI |
| `Discount_Type__c` | Picklist | Percentage / Fixed |
| `Discount_Value__c` | Number | % or currency amount |
| `Valid_From__c` | Date | |
| `Valid_To__c` | Date | |
| `Max_Uses__c` | Number | |
| `Current_Uses__c` | Number | Incremented on each successful booking |
| `Min_Order_Amount__c` | Currency | |
| `Applicable_Listing__c` | Lookup → `Booking_Listing__c` | Optional; null = applies to all |
| `Is_Active__c` | Checkbox | |

---

### Loyalty_Account__c — Points Wallet

| Field | Type | Notes |
|---|---|---|
| `Contact__c` | Lookup → Contact | |
| `Points_Balance__c` | Number | Current redeemable balance |
| `Points_Lifetime__c` | Number | All-time earned points |
| `Tier__c` | Picklist | Bronze / Silver / Gold |

---

### Payment_Method__c — Saved Gateway Methods

| Field | Type | Notes |
|---|---|---|
| `Contact__c` | Lookup → Contact | |
| `Label__c` | Text | e.g. `Visa ending 4242` |
| `Sub_Label__c` | Text | e.g. `Expires 12/27` |
| `Brand__c` | Text | visa / mastercard / paypal |
| `Gateway__c` | Picklist | Stripe / PayPal |
| `Gateway_Method_Id__c` | Text | Stripe PM ID stored server-side |
| `Is_Active__c` | Checkbox | |

---

### BookingEvent__e — Platform Event

| Field | Type | Notes |
|---|---|---|
| `Booking_Id__c` | Text | Salesforce record ID |
| `Reference__c` | Text | `BK-XXXXXXXX` |
| `Event_Type__c` | Text | `BOOKING_CONFIRMED` / `BOOKING_CANCELLED` |

Published by `EventBus.publish()` at the end of `processPayment()`. Consumed by a Platform Event-Triggered Flow that dispatches confirmation email and SMS.

---

## 7. Architecture Diagrams

### Overall architecture — four swimlanes

<img width="4300" height="2900" alt="01-overall-architecture" src="https://github.com/user-attachments/assets/ae05c54a-5b10-4da4-9446-a02c6480d4ec" />


### Pricing pipeline

<img width="4300" height="2800" alt="03-pricing-promotions" src="https://github.com/user-attachments/assets/0445770f-9714-4847-b6db-05aa9a37ccb0" />


### Payment flow

<img width="4300" height="2800" alt="04-payment-processing" src="https://github.com/user-attachments/assets/0c39068c-d657-4eea-849a-85bdd8105e5c" />

---

## 8. Project File Structure

```
salesforce-booking-portal/
├── sfdx-project.json
└── force-app/
    └── main/
        └── default/
            ├── classes/
            │   ├── BookingEngineController.cls
            │   ├── BookingEngineController.cls-meta.xml
            │   ├── PricingController.cls
            │   ├── PricingController.cls-meta.xml
            │   ├── PaymentController.cls
            │   └── PaymentController.cls-meta.xml
            └── lwc/
                ├── bookingCheckoutStepper/
                │   ├── bookingCheckoutStepper.html
                │   ├── bookingCheckoutStepper.js
                │   ├── bookingCheckoutStepper.css
                │   └── bookingCheckoutStepper.js-meta.xml
                ├── resourceSelector/
                │   ├── resourceSelector.html
                │   ├── resourceSelector.js
                │   ├── resourceSelector.css
                │   └── resourceSelector.js-meta.xml
                ├── pricingPanel/
                │   ├── pricingPanel.html
                │   ├── pricingPanel.js
                │   ├── pricingPanel.css
                │   └── pricingPanel.js-meta.xml
                ├── paymentProcessor/
                │   ├── paymentProcessor.html
                │   ├── paymentProcessor.js
                │   ├── paymentProcessor.css
                │   └── paymentProcessor.js-meta.xml
                └── bookingConfirmation/
                    ├── bookingConfirmation.html
                    ├── bookingConfirmation.js
                    ├── bookingConfirmation.css
                    └── bookingConfirmation.js-meta.xml
```

---

## 9. Prerequisites

| Requirement | Version / Detail |
|---|---|
| Salesforce Developer Org | Any edition with API access |
| Salesforce CLI (`sf`) | v2.x (`npm install -g @salesforce/cli`) |
| Node.js | 18 LTS or higher |
| Stripe account | Sandbox (test) keys from `dashboard.stripe.com` |
| PayPal Developer account | Sandbox app from `developer.paypal.com` |
| API version | 61.0 (Summer '24) |

Enable these in your org before deploying:
- Lightning Experience (`Setup → Lightning Experience`)
- Platform Events (`Setup → Integrations → Platform Events`)
- Digital Experiences (if deploying to a Community / Experience Cloud page)

---

## 10. Setup Guide

> Complete all five steps in order before testing. The LWC components will fail silently if any step is skipped.

---

### Step 1 — Stripe Named Credential

The Stripe secret key must be stored as a Named Credential so Apex can make server-side callouts without exposing the key in code.

#### 1.1 Create an External Credential

```
Setup → Security → Named Credentials → External Credentials tab → New
```

| Field | Value |
|---|---|
| Label | `Stripe_External_Cred` |
| Name | `Stripe_External_Cred` |
| Authentication Protocol | `Custom (No Authentication)` |

Click **Save**.

Inside the new External Credential, go to **Custom Headers → New**:

| Field | Value |
|---|---|
| Name | `Authorization` |
| Value | `Bearer sk_test_YOUR_STRIPE_SECRET_KEY` |

> Replace `sk_test_YOUR_STRIPE_SECRET_KEY` with the secret key from `dashboard.stripe.com/apikeys`. Never commit this value to source control.

#### 1.2 Create the Named Credential

```
Setup → Security → Named Credentials → Named Credentials tab → New
```

| Field | Value |
|---|---|
| Label | `Stripe_API` |
| Name | `Stripe_API` |
| URL | `https://api.stripe.com` |
| External Credential | `Stripe_External_Cred` |
| Allow Formulas in HTTP Header | ☑ |
| Allow Formulas in HTTP Body | ☑ |

Click **Save**.

> The name `Stripe_API` must match the constant `STRIPE_NAMED_CRED = 'Stripe_API'` in `PaymentController.cls` line 4.

#### 1.3 Add Remote Site Setting

```
Setup → Security → Remote Site Settings → New
```

| Field | Value |
|---|---|
| Remote Site Name | `Stripe_API` |
| Remote Site URL | `https://api.stripe.com` |
| Active | ☑ |

#### 1.4 Grant Permission Set access

```
Setup → Users → Permission Sets → [Your Permission Set] → External Credential Principal Access → Edit → Add Stripe_External_Cred
```

#### 1.5 Verify with a test callout

Open **Developer Console → Debug → Open Execute Anonymous Window** and run:

```apex
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:Stripe_API/v1/balance');
req.setMethod('GET');
HttpResponse res = new Http().send(req);
System.debug(res.getStatusCode() + ' ' + res.getBody());
```

Expected: `200` with a JSON balance response from Stripe.

---

### Step 2 — PayPal Named Credential

PayPal uses OAuth 2.0 Client Credentials — Salesforce handles token refresh automatically via the External Credential.

#### 2.1 Get sandbox credentials

1. Log in to `developer.paypal.com`
2. Go to **Apps & Credentials → Sandbox**
3. Copy the **Client ID** and **Secret** for your app

#### 2.2 Create an External Credential for PayPal

```
Setup → Security → Named Credentials → External Credentials tab → New
```

| Field | Value |
|---|---|
| Label | `PayPal_External_Cred` |
| Name | `PayPal_External_Cred` |
| Authentication Protocol | `OAuth 2.0` |
| Flow Type | `Client Credentials` |
| Token Endpoint URL | `https://api-m.sandbox.paypal.com/v1/oauth2/token` |
| Client ID | *(your PayPal sandbox client ID)* |
| Client Secret | *(your PayPal sandbox secret)* |

Click **Save**.

#### 2.3 Create the Named Credential

```
Setup → Security → Named Credentials → Named Credentials tab → New
```

| Field | Value |
|---|---|
| Label | `PayPal_API` |
| Name | `PayPal_API` |
| URL | `https://api-m.sandbox.paypal.com` |
| External Credential | `PayPal_External_Cred` |
| Generate Authorization Header | ☑ |

#### 2.4 Add Remote Site Settings

```
Setup → Security → Remote Site Settings → New
```

Add both entries:

| Remote Site Name | Remote Site URL |
|---|---|
| `PayPal_Sandbox` | `https://api-m.sandbox.paypal.com` |
| `PayPal_Auth` | `https://api-m.sandbox.paypal.com` |

#### 2.5 Grant Permission Set access

Same as Stripe: add `PayPal_External_Cred` to the Permission Set's **External Credential Principal Access**.

#### 2.6 Verify with a test callout

```apex
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:PayPal_API/v2/checkout/orders');
req.setMethod('POST');
req.setHeader('Content-Type', 'application/json');
req.setBody('{"intent":"CAPTURE","purchase_units":[{"amount":{"currency_code":"USD","value":"10.00"}}]}');
HttpResponse res = new Http().send(req);
System.debug(res.getStatusCode() + ' ' + res.getBody());
```

Expected: `201` with a JSON body containing `id` (order ID) and a `links` array including an `approve` URL.

---

### Step 3 — Custom Metadata Type

`Payment_Gateway_Config__mdt` stores the Stripe publishable key and default tax rate. Unlike Custom Settings, Custom Metadata is deployable and does not require a separate data migration.

#### 3.1 Create the metadata type

```
Setup → Custom Code → Custom Metadata Types → New
```

| Field | Value |
|---|---|
| Label | `Payment Gateway Config` |
| Plural Label | `Payment Gateway Configs` |
| Object Name | `Payment_Gateway_Config` |

Click **Save**. The full API name is `Payment_Gateway_Config__mdt`.

#### 3.2 Add custom fields

On the detail page, click **Custom Fields → New** three times:

| Field Label | API Name | Type | Details |
|---|---|---|---|
| Stripe Publishable Key | `Stripe_Publishable_Key__c` | Text | Length 300 |
| Default Tax Rate | `Default_Tax_Rate__c` | Number | Length 5, Decimals 2 |
| Is Live Mode | `Is_Live_Mode__c` | Checkbox | Default: unchecked |

> Do **not** store the Stripe secret key here. Only the publishable key (safe for client-side JS) belongs in this field.

#### 3.3 Create the Default record

```
Setup → Custom Code → Custom Metadata Types → Payment Gateway Config → Manage Records → New
```

| Field | Value |
|---|---|
| Label | `Default` |
| Name (DeveloperName) | `Default` |
| Stripe Publishable Key | `pk_test_YOUR_STRIPE_PUBLISHABLE_KEY` |
| Default Tax Rate | `8.50` |
| Is Live Mode | ☐ (unchecked for sandbox) |

> The `DeveloperName` must be `Default` exactly. `PaymentController.cls` queries `WHERE DeveloperName = 'Default'`.

#### 3.4 Verify the Apex query

```apex
Payment_Gateway_Config__mdt cfg = [
    SELECT Stripe_Publishable_Key__c, Default_Tax_Rate__c
    FROM   Payment_Gateway_Config__mdt
    WHERE  DeveloperName = 'Default'
    LIMIT  1
];
System.debug(cfg.Stripe_Publishable_Key__c);
```

Expected: your `pk_test_...` key in the debug log. If you see `QueryException: List has no rows`, the `DeveloperName` on the record doesn't match.

---

### Step 4 — Stripe.js Static Resource

LWC components cannot load external scripts directly from CDN URLs due to Salesforce CSP rules. Stripe.js must be hosted as a Static Resource.

#### 4.1 Download Stripe.js

```bash
curl -o StripeJS.js https://js.stripe.com/v3/
```

> This downloads the Stripe loader script. Verify the file is non-empty (should be ~50 KB). If you need the full self-contained SDK, use `unpkg.com/stripe-js` instead.

#### 4.2 Upload as a Static Resource

```
Setup → Custom Code → Static Resources → New
```

| Field | Value |
|---|---|
| Name | `StripeJS` |
| File | *(select the StripeJS.js file you downloaded)* |
| Cache Control | `Public` |
| Description | `Stripe.js v3 SDK for LWC payment elements` |

> The name `StripeJS` must match the import `@salesforce/resourceUrl/StripeJS` in `paymentProcessor.js` line 3. Any mismatch causes a deploy error.

#### 4.3 Add CSP Trusted Sites

Stripe Elements renders card inputs inside cross-origin iframes. All four domains must be trusted:

```
Setup → Security → CSP Trusted Sites → New (×4)
```

| CSP Trusted Site Name | Endpoint URL | Context |
|---|---|---|
| `Stripe_JS` | `https://js.stripe.com` | All |
| `Stripe_API` | `https://api.stripe.com` | All |
| `Stripe_M_Stripe` | `https://m.stripe.com` | All |
| `Stripe_M_Network` | `https://m.stripe.network` | All |

> Missing any one of these causes the card input fields to render as blank white boxes with no placeholder text. Check the browser console for `net::ERR_BLOCKED_BY_CSP` errors.

#### 4.4 Confirm the import in paymentProcessor.js

Open `force-app/main/default/lwc/paymentProcessor/paymentProcessor.js` and verify line 3:

```javascript
import STRIPE_JS from '@salesforce/resourceUrl/StripeJS';
```

And verify `connectedCallback()` calls `loadScript(this, STRIPE_JS)` before any `Stripe(...)` invocation.

---

### Step 5 — Deploy to Lightning Page

#### 5.1 Authenticate and push source

```bash
# Authenticate to your Developer Org
sf org login web --alias my-devorg

# Push all source files
sf project deploy start \
  --source-dir force-app \
  --target-org my-devorg
```

> If the deploy fails with a code coverage error, write test classes for all three Apex controllers (minimum 75% coverage required for any deployment to a non-scratch org).

#### 5.2 Open Lightning App Builder

```
Setup → User Interface → Lightning App Builder → New
```

Choose a page type:

| Page Type | Best for |
|---|---|
| App Page | Standalone portal in a custom Lightning app |
| Record Page | Booking widget on Contact or Account detail |
| Home Page | Quick access widget on the org home tab |
| Experience Cloud Page | Public-facing customer-facing portal |

#### 5.3 Add the component to the canvas

In the left component panel, search for **bookingCheckoutStepper**. Drag it into a **full-width region** (12-column or single-column layout) to give the 4-step wizard enough horizontal space.

#### 5.4 Configure Experience Cloud properties (optional)

If the page type is Experience Cloud, a property panel appears on the right side of App Builder. Set the **Page Title** (default: `Book Now`). This maps to the `title` property defined in `bookingCheckoutStepper.js-meta.xml`:

```xml
<targetConfig targets="lightningCommunity__Page">
    <property name="title" type="String" label="Page Title" default="Book Now"/>
</targetConfig>
```

#### 5.5 Save and activate

Click **Save → Activate**. Choose the activation scope:

| Option | Use when |
|---|---|
| Assign as Org Default | All users see this page |
| Assign to Apps | Only users of selected Lightning apps |
| Assign to Profiles | Specific user profiles only |

For a customer-facing portal: assign to the **Customer Community Plus** profile or **Guest User** profile (Experience Cloud only), not System Administrator.

---

## 11. End-to-End Data Flow

The complete booking journey in 15 steps:

```
 1. User enters type + date + party size → searchAvailability() SOQL
 2. Resource cards rendered with available time slots
 3. User selects a slot → createHold() → Booking_Hold__c (TTL 10 min)
 4. 10-minute countdown starts in the UI
 5. calculatePrice() runs the full pipeline → itemised breakdown shown
 6. User enters/validates a promo code → validatePromoCode() (6 checks)
 7. Total recalculates; loyalty points toggle shown if balance > 0
 8. User enters Stripe card → tokenizeCard() → paymentMethodId
 9. processPayment() called → Stripe /v1/payment_intents confirm callout
10. INSERT Booking__c (Status = Confirmed, Reference = BK-XXXXXXXX)
11. UPDATE Booking_Hold__c (Status = Released)
12. UPDATE Promo_Code__c.Current_Uses__c + 1
13. UPDATE Loyalty_Account__c.Points_Balance__c − loyaltyPts
14. PUBLISH BookingEvent__e → Platform Event-Triggered Flow → Email + SMS
15. bookingReference returned to LWC → Step 4 (Confirmation) renders
```

**Error paths:**
- Hold expires (step 4 countdown → 0): `releaseHold()` called, user returned to step 1 with error toast
- Stripe charge fails (step 9): `AuraHandledException` thrown, `stripeError` displayed, no `Booking__c` inserted
- Invalid promo (step 6): server returns `reason` string, total unchanged, red error message shown

---

## 12. Smoke Test Checklist

Run these tests manually after deployment:

| # | Test | Expected result |
|---|---|---|
| 1 | Search with a valid date + party size | Resource cards render with time slots |
| 2 | Select a slot and click Confirm Selection | Hold created, 10-min countdown appears at bottom |
| 3 | Wait for hold to expire | User returned to step 1 with error toast |
| 4 | Apply promo code `TEST10` (create one first) | Discount line appears, total recalculates |
| 5 | Toggle loyalty points on | Loyalty savings line appears, total recalculates |
| 6 | Enter Stripe test card `4242 4242 4242 4242`, any future expiry, any CVC | No Stripe error, Pay button enabled |
| 7 | Submit payment | Booking reference shown (e.g. `BK-A1B2C3D4`) |
| 8 | Copy reference button | "Copied!" label appears for 2 seconds |
| 9 | Click Add to Google Calendar | Google Calendar tab opens with event pre-filled |
| 10 | Click Outlook / iCal | `.ics` file downloads |
| 11 | Click Download Invoice | PDF downloads (requires `BookingInvoicePDF` VF page deployed) |
| 12 | Click View My Bookings | Navigates to `My_Bookings` nav item page |

**Stripe test card numbers:**

| Card number | Scenario |
|---|---|
| `4242 4242 4242 4242` | Success |
| `4000 0000 0000 9995` | Declined (insufficient funds) |
| `4000 0025 0000 3155` | 3D Secure authentication required |

---

## 13. Platform Automation

Three Flows are required to complete the automation layer:

### Scheduled Flow — Hold Expiry Cleanup

- **Trigger:** Scheduled (runs every 5 minutes)
- **Action:** Query `Booking_Hold__c` where `Status__c = 'Active'` AND `Expires_At__c < NOW()` → update `Status__c = 'Expired'`

### Record-Triggered Flow — Booking Status Change

- **Trigger:** `Booking__c` after save (created or updated)
- **Condition:** `Status__c` changed to `Cancelled`
- **Action:** Calculate refund amount based on `Cancellation_Penalty_Pct__c`, create `Refund__c` record

### Platform Event-Triggered Flow — Confirmation Notifications

- **Trigger:** `BookingEvent__e` received
- **Condition:** `Event_Type__c = 'BOOKING_CONFIRMED'`
- **Action 1:** Send confirmation email via `Send Email` action
- **Action 2:** Send SMS via Twilio integration (or OmniChannel messaging)

---

## 14. Security & Permissions

All Apex controllers use `with sharing` — records are filtered by the running user's sharing rules.

All SOQL queries use `WITH SECURITY_ENFORCED` — field-level and object-level security is enforced at query time.

### Minimum Permission Set configuration

Create a Permission Set and assign it to all users who access the booking portal:

| Permission | Reason |
|---|---|
| `Booking_Listing__c` — Read | Search and display listings |
| `Booking_Hold__c` — Read, Create, Edit | Create and release holds |
| `Booking__c` — Read, Create | Create and view bookings |
| `Promo_Code__c` — Read | Validate promo codes |
| `Loyalty_Account__c` — Read, Edit | Read and deduct loyalty points |
| `Payment_Method__c` — Read | Display saved methods |
| `BookingEvent__e` — Create | Publish platform events |
| External Credential Principal Access: `Stripe_External_Cred` | Stripe callouts |
| External Credential Principal Access: `PayPal_External_Cred` | PayPal callouts |
| Apex Class Access: `BookingEngineController` | All booking engine methods |
| Apex Class Access: `PricingController` | All pricing methods |
| Apex Class Access: `PaymentController` | All payment methods |

---

## 15. Going Live Checklist

Before switching from sandbox to production:

- [ ] Replace `pk_test_...` with `pk_live_...` in `Payment_Gateway_Config__mdt`
- [ ] Replace `sk_test_...` with `sk_live_...` in the Stripe Named Credential header
- [ ] Update PayPal Named Credential URL from `api-m.sandbox.paypal.com` to `api-m.paypal.com`
- [ ] Update PayPal token endpoint URL in External Credential to `https://api.paypal.com/v1/oauth2/token`
- [ ] Update Remote Site Settings to use production domains
- [ ] Set `Is_Live_Mode__c = true` on the `Payment_Gateway_Config__mdt` record
- [ ] Enable PCI-DSS compliance logging on `Payment__c` records
- [ ] Configure a Stripe webhook endpoint to handle asynchronous events (disputes, refunds)
- [ ] Set Stripe webhook secret in a second Named Credential for signature verification
- [ ] Run all smoke tests against production with a real card and immediately issue a refund
- [ ] Set org-wide default sharing on `Booking__c` to `Private` (users see only their own bookings)
- [ ] Enable Salesforce Shield Encryption on `Transaction_Id__c` and `Payment_Method_Id__c` fields
- [ ] Review and lock down Guest User profile permissions if using Experience Cloud

---

## Contributing

1. Fork or clone this repository
2. Create a scratch org: `sf org create scratch -f config/project-scratch-def.json -a booking-scratch`
3. Push source: `sf project deploy start --target-org booking-scratch`
4. Run tests: `sf apex run test --target-org booking-scratch --result-format human`
5. Open a pull request with a description of the change and test results

---

*Built for Salesforce Developer Org · API v61.0 · Summer '24*
