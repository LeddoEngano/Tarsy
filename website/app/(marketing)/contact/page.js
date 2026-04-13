import ContactForm from "./ContactForm";
import { WebPageJsonLd } from "../../components/JsonLd";

export const metadata = {
  title: "Contact",
  description:
    "Contact the Tarsy team for support, bug reports, feature requests, or business inquiries. We respond within 24 hours.",
  alternates: {
    canonical: "https://www.tarsy.dev/contact",
  },
};

export default function ContactPage() {
  return (
    <>
      <WebPageJsonLd
        url="https://www.tarsy.dev/contact"
        name="Contact Tarsy"
        description="Contact the Tarsy team for support, bug reports, feature requests, or business inquiries."
        breadcrumbs={[
          { name: "Home", url: "https://www.tarsy.dev" },
          { name: "Contact", url: "https://www.tarsy.dev/contact" },
        ]}
      />
      <ContactForm />
    </>
  );
}
