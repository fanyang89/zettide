package command

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"strings"
	"text/tabwriter"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

type printer struct {
	w      io.Writer
	format string
}

func newPrinter(w io.Writer, format string) *printer {
	return &printer{w: w, format: format}
}

func (p *printer) print(message proto.Message) error {
	if p.format == "json" {
		encoded, err := (protojson.MarshalOptions{
			Multiline:       true,
			Indent:          "  ",
			UseProtoNames:   true,
			EmitUnpopulated: true,
		}).Marshal(message)
		if err != nil {
			return fmt.Errorf("encode JSON: %w", err)
		}
		_, err = fmt.Fprintf(p.w, "%s\n", encoded)
		return err
	}
	return p.printTable(message.ProtoReflect())
}

func (p *printer) printTable(message protoreflect.Message) error {
	fields := message.Descriptor().Fields()
	for i := 0; i < fields.Len(); i++ {
		field := fields.Get(i)
		if field.IsList() && field.Kind() == protoreflect.MessageKind {
			if err := p.printMessageList(message.Get(field).List(), field.Message()); err != nil {
				return err
			}
			return p.printPageToken(message)
		}
	}
	if fields.Len() == 1 && fields.Get(0).Kind() == protoreflect.MessageKind && message.Has(fields.Get(0)) {
		return p.printVertical(message.Get(fields.Get(0)).Message())
	}
	return p.printVertical(message)
}

func (p *printer) printMessageList(list protoreflect.List, descriptor protoreflect.MessageDescriptor) error {
	tw := tabwriter.NewWriter(p.w, 0, 4, 2, ' ', 0)
	fields := descriptor.Fields()
	for i := 0; i < fields.Len(); i++ {
		if i > 0 {
			fmt.Fprint(tw, "\t")
		}
		fmt.Fprint(tw, strings.ToUpper(string(fields.Get(i).Name())))
	}
	fmt.Fprintln(tw)
	for row := 0; row < list.Len(); row++ {
		message := list.Get(row).Message()
		for column := 0; column < fields.Len(); column++ {
			if column > 0 {
				fmt.Fprint(tw, "\t")
			}
			field := fields.Get(column)
			fmt.Fprint(tw, sanitizeCell(formatValue(message.Get(field), field)))
		}
		fmt.Fprintln(tw)
	}
	if list.Len() == 0 {
		fmt.Fprintln(tw, "(no rows)")
	}
	return tw.Flush()
}

func (p *printer) printVertical(message protoreflect.Message) error {
	tw := tabwriter.NewWriter(p.w, 0, 4, 2, ' ', 0)
	fields := message.Descriptor().Fields()
	for i := 0; i < fields.Len(); i++ {
		field := fields.Get(i)
		fmt.Fprintf(tw, "%s\t%s\n", strings.ToUpper(string(field.Name())), sanitizeCell(formatValue(message.Get(field), field)))
	}
	return tw.Flush()
}

func (p *printer) printPageToken(message protoreflect.Message) error {
	fields := message.Descriptor().Fields()
	for i := 0; i < fields.Len(); i++ {
		field := fields.Get(i)
		if field.Name() == "next_page_token" {
			token := message.Get(field).Bytes()
			if len(token) != 0 {
				_, err := fmt.Fprintf(p.w, "NEXT_PAGE_TOKEN\t%s\n", base64.StdEncoding.EncodeToString(token))
				return err
			}
		}
	}
	return nil
}

func formatValue(value protoreflect.Value, field protoreflect.FieldDescriptor) string {
	if field.IsList() {
		list := value.List()
		values := make([]string, 0, list.Len())
		for i := 0; i < list.Len(); i++ {
			values = append(values, formatSingular(list.Get(i), field))
		}
		return strings.Join(values, ",")
	}
	return formatSingular(value, field)
}

func formatSingular(value protoreflect.Value, field protoreflect.FieldDescriptor) string {
	switch field.Kind() {
	case protoreflect.BytesKind:
		if len(value.Bytes()) == 0 {
			return ""
		}
		if strings.Contains(string(field.Name()), "page_token") {
			return base64.StdEncoding.EncodeToString(value.Bytes())
		}
		return hex.EncodeToString(value.Bytes())
	case protoreflect.EnumKind:
		enumValue := field.Enum().Values().ByNumber(value.Enum())
		if enumValue == nil {
			return fmt.Sprint(value.Enum())
		}
		return string(enumValue.Name())
	case protoreflect.MessageKind, protoreflect.GroupKind:
		if !value.Message().IsValid() {
			return ""
		}
		encoded, err := (protojson.MarshalOptions{UseProtoNames: true}).Marshal(value.Message().Interface())
		if err != nil {
			return "<invalid>"
		}
		return string(encoded)
	default:
		return fmt.Sprint(value.Interface())
	}
}

func sanitizeCell(value string) string {
	value = strings.ReplaceAll(value, "\t", " ")
	return strings.ReplaceAll(value, "\n", "\\n")
}
